package com.meowagent.meow_agent

import android.content.Context
import android.os.Build
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.BufferedInputStream
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import java.util.zip.GZIPInputStream
import org.tukaani.xz.XZInputStream

/**
 * Native VM runtime manager.
 *
 * The runtime is a proot-based Linux chroot living at:
 *   {filesDir}/vm-runtime/rootfs/
 *
 * The proot binary and libtalloc are downloaded in-app into internal storage.
 * They are intentionally not bundled in the APK so the base install stays
 * small; the user triggers installation from the VM Runtime screen.
 *
 * The rootfs is expected to be a {@code .tar.gz} tarball. We extract using a
 * minimal inline reader (no commons-compress dep). The default preset URL
 * lives Dart-side; the native side only validates the SHA-256 (when supplied)
 * and writes the extracted tree to disk.
 */
class VmRuntimeManager(private val context: Context) {

    private val mutex = Mutex()
    private val sessionMutex = Mutex()

    // @Volatile so the UI can poll snapshot() during a long-running download
    // (which holds the mutex). The lock is only for serialising operations,
    // not for reads.
    @Volatile private var status: String = STATUS_UNKNOWN
    @Volatile private var lastMessage: String = ""
    @Volatile private var runtimeVersion: String = ""

    // Persistent proot session fields.
    @Volatile private var sessionProcess: Process? = null
    private var sessionStdin: java.io.BufferedWriter? = null
    private var sessionStdoutReader: Thread? = null
    private val sessionOutputBuffer = java.util.concurrent.LinkedBlockingQueue<String>()

    private val rootfsDir: File
        get() = File(context.filesDir, "vm-runtime/rootfs")

    private val workspaceDir: File
        get() = File(context.filesDir, "vm-runtime/workspace")

    private val downloadDir: File
        get() = File(context.filesDir, "vm-runtime/downloads")

    private val binDir: File
        get() = File(context.applicationInfo.nativeLibraryDir)

    private val stagedProot: File
        get() = File(binDir, "libproot.so")

    /// Companion binary that proot uses to bypass Android 10+ W^X.
    /// Bundled in jniLibs as libproot-loader.so so Android places it on an
    /// executable mount point (nativeLibraryDir). PROOT_LOADER env points here.
    private val stagedLoader: File
        get() = File(binDir, "libproot-loader.so")

    private val stagedTalloc: File
        get() = File(binDir, "libtalloc.so")

    /// Shared-memory shim required by proot 5.1.107.78+.
    private val stagedShmem: File
        get() = File(binDir, "libandroid-shmem.so")

    private val binariesInstalled: Boolean
        get() = stagedProot.exists() &&
            stagedLoader.exists() &&
            stagedTalloc.exists() &&
            stagedShmem.exists() &&
            stagedProot.length() > 0 &&
            stagedLoader.length() > 0 &&
            stagedTalloc.length() > 0 &&
            stagedShmem.length() > 0

    fun snapshot(): Map<String, Any?> {
        val installed = isRootfsInstalled()
        val hasBinaries = binariesInstalled
        val resolvedStatus = when {
            !hasBinaries && status == STATUS_UNKNOWN -> STATUS_NOT_INSTALLED
            !installed && status == STATUS_UNKNOWN -> STATUS_NOT_INSTALLED
            installed && status == STATUS_UNKNOWN -> STATUS_INSTALLED
            else -> status
        }
        return mapOf(
            "status" to resolvedStatus,
            "native_runtime_available" to true,
            "runtime_binaries_installed" to hasBinaries,
            "runtime_binary_path" to stagedProot.absolutePath,
            "rootfs_installed" to installed,
            "service_running" to (status == STATUS_RUNNING),
            "runtime_version" to runtimeVersion,
            "rootfs_path" to rootfsDir.absolutePath,
            "workspace_path" to workspaceDir.absolutePath,
            "message" to lastMessage,
            "updated_at" to System.currentTimeMillis().toString()
        )
    }

    private fun isRootfsInstalled(): Boolean {
        return File(rootfsDir, "bin/sh").exists() ||
            File(rootfsDir, "usr/bin/sh").exists() ||
            File(rootfsDir, "bin/dash").exists() ||
            File(rootfsDir, "usr/bin/dash").exists() ||
            File(rootfsDir, "bin/bash").exists() ||
            File(rootfsDir, "usr/bin/bash").exists()
    }

    private fun ensureBinariesInstalled(onProgress: (String) -> Unit) {
        // Binaries are bundled in the APK via jniLibs/arm64-v8a/ and extracted
        // by Android to nativeLibraryDir at install time. No download needed.
        // Just verify they're present — if not, the APK is misconfigured.
        if (!binariesInstalled) {
            throw IOException(
                "VM runtime binaries not found in native library directory. " +
                "Ensure libproot.so, libproot-loader.so, libtalloc.so, and " +
                "libandroid-shmem.so are in jniLibs/arm64-v8a/."
            )
        }
        // proot's dynamic linker expects exact sonames: libtalloc.so.2 and
        // libandroid-shmem.so (no version). nativeLibraryDir only has the
        // Android-mandated names (lib*.so). Create symlinks with the names
        // the linker expects in a writable dir so LD_LIBRARY_PATH resolves.
        ensureLinkerSymlinks()
    }

    /// Directory for symlinks that map sonames proot expects to the actual
    /// bundled .so files in nativeLibraryDir.
    private val libSymlinkDir: File
        get() = File(context.codeCacheDir, "vm-runtime/lib")

    private fun ensureLinkerSymlinks() {
        libSymlinkDir.mkdirs()
        // libtalloc.so.2 → libtalloc.so
        createSymlinkIfNeeded(
            link = File(libSymlinkDir, "libtalloc.so.2"),
            target = stagedTalloc,
        )
        // libandroid-shmem.so → keep same name (no version suffix needed)
        createSymlinkIfNeeded(
            link = File(libSymlinkDir, "libandroid-shmem.so"),
            target = stagedShmem,
        )
    }

    private fun createSymlinkIfNeeded(link: File, target: File) {
        if (link.exists()) link.delete()
        try {
            java.nio.file.Files.createSymbolicLink(
                link.toPath(),
                target.toPath(),
            )
        } catch (e: Exception) {
            // Fallback: copy the file if symlinks aren't supported.
            target.copyTo(link, overwrite = true)
        }
    }

    private fun downloadFile(url: String, target: File) {
        val connection = URL(url).openConnection()
        connection.connectTimeout = 30_000
        connection.readTimeout = 60_000
        BufferedInputStream(connection.getInputStream()).use { source ->
            FileOutputStream(target).use { sink ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    val read = source.read(buffer)
                    if (read < 0) break
                    sink.write(buffer, 0, read)
                }
            }
        }
    }

    private fun extractDataTar(archive: File, target: File) {
        when {
            archive.name.endsWith(".xz") -> {
                XZInputStream(archive.inputStream().buffered()).use { input ->
                    extractTar(input, target)
                }
            }
            archive.name.endsWith(".gz") -> {
                GZIPInputStream(archive.inputStream().buffered()).use { input ->
                    extractTar(input, target)
                }
            }
            else -> {
                archive.inputStream().buffered().use { input ->
                    extractTar(input, target)
                }
            }
        }
    }

    suspend fun downloadRootfs(
        url: String,
        sha256: String,
        version: String,
        onProgress: (String) -> Unit = {}
    ): Map<String, Any?> = mutex.withLock {
        try {
            status = STATUS_DOWNLOADING
            ensureBinariesInstalled(onProgress)
            lastMessage = "Downloading rootfs..."
            onProgress(lastMessage)

            downloadDir.mkdirs()
            val tarball = File(downloadDir, "rootfs.tar.gz")
            if (tarball.exists()) tarball.delete()

            // Download with progress.
            val connection = URL(url).openConnection()
            connection.connectTimeout = 30_000
            connection.readTimeout = 60_000
            val totalBytes = connection.contentLengthLong
            val sink = FileOutputStream(tarball)
            val source = BufferedInputStream(connection.getInputStream())
            val digest = MessageDigest.getInstance("SHA-256")
            val buffer = ByteArray(64 * 1024)
            var read = 0L
            var lastReportedPct = -1
            while (true) {
                val n = source.read(buffer)
                if (n < 0) break
                sink.write(buffer, 0, n)
                digest.update(buffer, 0, n)
                read += n
                if (totalBytes > 0) {
                    val pct = ((read * 100) / totalBytes).toInt()
                    if (pct != lastReportedPct) {
                        lastReportedPct = pct
                        val mb = read / 1_000_000
                        val totalMb = totalBytes / 1_000_000
                        // UI reads this via snapshot() polling.
                        lastMessage = "Downloading $pct% ($mb / $totalMb MB)"
                        if (pct % 5 == 0) onProgress(lastMessage)
                    }
                } else {
                    val mb = read / 1_000_000
                    lastMessage = "Downloading... $mb MB"
                }
            }
            sink.close()
            source.close()

            // Verify checksum unless caller passes a placeholder.
            if (sha256.isNotEmpty() && !sha256.all { it == '0' }) {
                val actual = digest.digest().joinToString("") { "%02x".format(it) }
                if (!actual.equals(sha256, ignoreCase = true)) {
                    return@withLock fail(
                        "Checksum mismatch. Expected $sha256, got $actual."
                    )
                }
            }

            onProgress("extracting")
            lastMessage = "Verifying and extracting..."
            // Wipe and recreate.
            if (rootfsDir.exists()) rootfsDir.deleteRecursively()
            rootfsDir.mkdirs()
            extractTarGz(tarball, rootfsDir)
            tarball.delete()

            lastMessage = "Configuring runtime..."
            // Make the chroot usable: inject DNS + workspace mount point.
            // Without resolv.conf, apt-get / curl / npm all fail with NXDOMAIN.
            configureRootfs()

            workspaceDir.mkdirs()

            // Bootstrap: install essential tools that plugins and apt/dpkg need.
            // This runs once after extraction so individual plugin installs stay
            // simple and don't each need to pull common dependencies.
            lastMessage = "Installing base tools..."
            bootstrapRootfs()
            runtimeVersion = version
            // Auto-promote to RUNNING. The user's mental model is
            // "Download → Done". A separate Start tap is power-user noise
            // (proot runs per-command, not as a long-lived service).
            status = STATUS_RUNNING
            lastMessage = ""
            return@withLock snapshot()
        } catch (e: IOException) {
            return@withLock fail("Download failed: ${e.message ?: e.javaClass.simpleName}")
        } catch (e: Exception) {
            return@withLock fail("Install failed: ${e.message ?: e.javaClass.simpleName}")
        }
    }

    suspend fun start(): Map<String, Any?> = mutex.withLock {
        if (!binariesInstalled) {
            return@withLock fail("Runtime binary is not installed. Tap Install Runtime first.")
        }
        if (!isRootfsInstalled()) {
            return@withLock fail("Runtime is not installed. Tap Install Runtime first.")
        }
        // If session already alive, just return running state.
        if (sessionProcess?.isAlive == true) {
            status = STATUS_RUNNING
            lastMessage = ""
            return@withLock snapshot()
        }
        try {
            startSession()
            status = STATUS_RUNNING
            lastMessage = ""
        } catch (e: Exception) {
            return@withLock fail("Failed to start session: ${e.message}")
        }
        snapshot()
    }

    suspend fun stop(): Map<String, Any?> = mutex.withLock {
        stopSession()
        status = STATUS_STOPPED
        lastMessage = ""
        snapshot()
    }

    val isSessionAlive: Boolean
        get() = sessionProcess?.isAlive == true

    private fun startSession() {
        configureRootfs()
        workspaceDir.mkdirs()
        val shellPath = shellPathInsideRootfs()
            ?: throw IOException("Runtime shell was not found in rootfs.")

        val pb = ProcessBuilder(
            listOf(
                linkerPath(),
                stagedProot.absolutePath,
                "-0",
                "--link2symlink",
                "--kill-on-exit",
                "-r", rootfsDir.absolutePath,
                "-w", "/root",
                "-b", "/dev",
                "-b", "/proc",
                "-b", "/sys",
                "-b", "${workspaceDir.absolutePath}:/root/workspace",
                shellPath,
            )
        )
        pb.environment().putAll(
            mapOf(
                "HOME" to "/root",
                "PATH" to "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                "TERM" to "xterm-256color",
                "LANG" to "C.UTF-8",
                "TMPDIR" to "/tmp",
                "TMP" to "/tmp",
                "TEMP" to "/tmp",
                "DEBIAN_FRONTEND" to "noninteractive",
                "DEBCONF_NONINTERACTIVE_SEEN" to "true",
                "LD_LIBRARY_PATH" to "${libSymlinkDir.absolutePath}:${binDir.absolutePath}",
                "PROOT_LOADER" to stagedLoader.absolutePath,
                "PROOT_TMP_DIR" to context.cacheDir.absolutePath
            )
        )
        pb.redirectErrorStream(true)

        val process = pb.start()
        sessionProcess = process
        sessionStdin = process.outputStream.bufferedWriter()

        // Background thread that reads stdout line-by-line and puts into queue.
        sessionStdoutReader = Thread({
            try {
                val reader = process.inputStream.bufferedReader()
                var line: String?
                while (reader.readLine().also { line = it } != null) {
                    sessionOutputBuffer.offer(line!!)
                }
            } catch (_: Exception) {
                // Process died or stream closed.
            } finally {
                if (status == STATUS_RUNNING) {
                    status = STATUS_ERROR
                    lastMessage = "Session exited unexpectedly."
                }
            }
        }, "proot-stdout-reader").also { it.isDaemon = true; it.start() }

        // Wait briefly for shell to be ready.
        Thread.sleep(200)
        if (!process.isAlive) {
            throw IOException("Proot process exited immediately.")
        }
    }

    private fun stopSession() {
        try {
            sessionStdin?.write("exit\n")
            sessionStdin?.flush()
        } catch (_: Exception) {}

        val proc = sessionProcess
        if (proc != null) {
            try { proc.waitFor(2, TimeUnit.SECONDS) } catch (_: Exception) {}
            if (proc.isAlive) proc.destroyForcibly()
        }
        sessionProcess = null
        sessionStdin = null
        sessionStdoutReader?.interrupt()
        sessionStdoutReader = null
        sessionOutputBuffer.clear()
    }

    /**
     * Run a command in the persistent session. Falls back to one-shot if
     * session is not alive.
     */
    suspend fun runCommand(
        command: String,
        timeoutMs: Long
    ): Map<String, Any?> = withContext(Dispatchers.IO) {
        if (sessionProcess?.isAlive == true) {
            return@withContext runCommandInSession(command, timeoutMs)
        }
        return@withContext runCommandOneShot(command, timeoutMs)
    }

    private suspend fun runCommandInSession(
        command: String,
        timeoutMs: Long
    ): Map<String, Any?> = sessionMutex.withLock {
        val marker = "___MEOW_END_${System.nanoTime()}___"
        val stdin = sessionStdin
            ?: return@withLock commandFail("Session stdin is not available.")

        // Drain any leftover output from previous commands.
        sessionOutputBuffer.clear()

        try {
            // Send the command followed by an end-marker echo.
            stdin.write(command)
            stdin.newLine()
            stdin.write("__meow_exit=\$?; echo \"$marker \$__meow_exit\"")
            stdin.newLine()
            stdin.flush()
        } catch (e: Exception) {
            return@withLock commandFail("Failed to write command: ${e.message}")
        }

        // Collect output lines until marker appears or timeout.
        val output = StringBuilder()
        val deadline = System.currentTimeMillis() + timeoutMs
        var exitCode = 0
        var found = false

        while (System.currentTimeMillis() < deadline) {
            val remaining = deadline - System.currentTimeMillis()
            if (remaining <= 0) break
            val line = sessionOutputBuffer.poll(
                remaining.coerceAtMost(200),
                TimeUnit.MILLISECONDS
            )
            if (line == null) {
                // Check if process died.
                if (sessionProcess?.isAlive != true) {
                    return@withLock commandFail("Session process died during command execution.")
                }
                continue
            }
            if (line.startsWith(marker)) {
                // Extract exit code from marker line.
                val parts = line.removePrefix(marker).trim()
                exitCode = parts.toIntOrNull() ?: 0
                found = true
                break
            }
            output.appendLine(line)
        }

        if (!found) {
            return@withLock mapOf(
                "success" to false,
                "exit_code" to -1,
                "stdout" to output.toString().trimEnd(),
                "stderr" to "",
                "message" to "Command timed out after ${timeoutMs}ms."
            )
        }

        mapOf(
            "success" to (exitCode == 0),
            "exit_code" to exitCode,
            "stdout" to output.toString().trimEnd(),
            "stderr" to "",
            "message" to ""
        )
    }

    /**
     * Post-extract setup that turns a bare rootfs into something usable.
     * Idempotent: safe to call repeatedly.
     */
    private fun configureRootfs() {
        try {
            val etc = File(rootfsDir, "etc")
            etc.mkdirs()
            // Public DNS so apt-get / curl / npm install all work.
            File(etc, "resolv.conf").writeText(
                "nameserver 8.8.8.8\nnameserver 1.1.1.1\n"
            )
            // Workspace mount point inside the chroot. Actual storage lives
            // outside the rootfs at workspaceDir; runCommand binds it.
            File(rootfsDir, "root/workspace").mkdirs()
            repairMergedUsrLinks()
            repairShellLinks()
        } catch (e: Exception) {
            Log.w(TAG, "configureRootfs: ${e.message}")
        }
    }

    private fun repairMergedUsrLinks() {
        ensureRootLinkOrCopy("bin", "usr/bin")
        ensureRootLinkOrCopy("sbin", "usr/sbin")
        ensureRootLinkOrCopy("lib", "usr/lib")
        ensureRootLinkOrCopy("lib64", "usr/lib64")
    }

    private fun ensureRootLinkOrCopy(linkName: String, targetName: String) {
        val link = File(rootfsDir, linkName)
        val target = File(rootfsDir, targetName)
        if (!target.exists()) return
        if (link.exists()) {
            if (!link.isDirectory || link.list()?.isNotEmpty() == true) return
            link.delete()
        } else if (java.nio.file.Files.isSymbolicLink(link.toPath())) {
            link.delete()
        }

        try {
            java.nio.file.Files.createSymbolicLink(
                link.toPath(),
                java.io.File(targetName).toPath()
            )
        } catch (_: Exception) {
            if (target.isDirectory) {
                copyDirectoryIfMissing(target, link)
            }
        }
    }

    private fun copyDirectoryIfMissing(source: File, destination: File) {
        if (destination.exists()) return
        source.walkTopDown().forEach { file ->
            val relative = file.relativeTo(source).path
            val out = if (relative == ".") destination else File(destination, relative)
            if (file.isDirectory) {
                out.mkdirs()
            } else if (!out.exists()) {
                out.parentFile?.mkdirs()
                file.copyTo(out, overwrite = false)
                out.setExecutable(file.canExecute(), false)
            }
        }
    }

    private fun repairShellLinks() {
        val dash = listOf(
            File(rootfsDir, "usr/bin/dash"),
            File(rootfsDir, "bin/dash"),
        ).firstOrNull { it.exists() }
        val usrSh = File(rootfsDir, "usr/bin/sh")
        if (!usrSh.exists() && dash != null) {
            usrSh.parentFile?.mkdirs()
            try {
                java.nio.file.Files.createSymbolicLink(
                    usrSh.toPath(),
                    java.io.File(dash.name).toPath()
                )
            } catch (_: Exception) {
                dash.copyTo(usrSh, overwrite = true)
                usrSh.setExecutable(true, false)
            }
        }
    }

    /**
     * Bootstrap essential tools after rootfs extraction. Runs once so that
     * individual plugin installs don't each need to pull common dependencies.
     * Failures here are non-fatal — we log and continue.
     */
    private suspend fun bootstrapRootfs() {
        // Ensure /tmp exists inside rootfs (mktemp needs it).
        val tmpDir = File(rootfsDir, "tmp")
        if (!tmpDir.exists()) tmpDir.mkdirs()

        val bootstrapCmd =
            "export DEBIAN_FRONTEND=noninteractive && " +
            "mkdir -p /tmp && chmod 1777 /tmp && " +
            "apt-get update && " +
            "apt-get install -y --no-install-recommends " +
            "apt-utils ca-certificates curl wget unzip gnupg"

        try {
            val result = runCommand(bootstrapCmd, 300000) // 5 min timeout
            val success = result["success"] as? Boolean ?: false
            if (!success) {
                Log.w(TAG, "Bootstrap non-fatal failure: ${result["stderr"]}")
            }
        } catch (e: Exception) {
            Log.w(TAG, "Bootstrap exception (non-fatal): ${e.message}")
        }
    }

    private fun shellPathInsideRootfs(): String? {
        return listOf(
            "/bin/sh" to File(rootfsDir, "bin/sh"),
            "/usr/bin/sh" to File(rootfsDir, "usr/bin/sh"),
            "/usr/bin/dash" to File(rootfsDir, "usr/bin/dash"),
            "/bin/dash" to File(rootfsDir, "bin/dash"),
            "/bin/bash" to File(rootfsDir, "bin/bash"),
            "/usr/bin/bash" to File(rootfsDir, "usr/bin/bash"),
        ).firstOrNull { (_, file) -> file.exists() }?.first
    }

    /**
     * One-shot: spawn a fresh proot process, run command, wait, return.
     * Used as fallback when session is not alive, and for bootstrap/install.
     */
    private suspend fun runCommandOneShot(
        command: String,
        timeoutMs: Long
    ): Map<String, Any?> = withContext(Dispatchers.IO) {
        if (!isRootfsInstalled()) {
            return@withContext commandFail("Runtime is not installed.")
        }
        if (!binariesInstalled) {
            try {
                mutex.withLock {
                    ensureBinariesInstalled { /* silent */ }
                }
            } catch (e: Exception) {
                return@withContext commandFail(
                    "Runtime binary could not be staged: " +
                        (e.message ?: e.javaClass.simpleName)
                )
            }
        }

        try {
            configureRootfs()
            val shellPath = shellPathInsideRootfs()
                ?: return@withContext commandFail("Runtime shell was not found in rootfs.")
            val pb = ProcessBuilder(
                listOf(
                    linkerPath(),
                    stagedProot.absolutePath,
                    "-0",
                    "--link2symlink",
                    "--kill-on-exit",
                    "-r", rootfsDir.absolutePath,
                    "-w", "/root",
                    "-b", "/dev",
                    "-b", "/proc",
                    "-b", "/sys",
                    "-b", "${workspaceDir.absolutePath}:/root/workspace",
                    shellPath, "-c", command,
                )
            )
            pb.environment().putAll(
                mapOf(
                    "HOME" to "/root",
                    "PATH" to "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                    "TERM" to "xterm-256color",
                    "LANG" to "C.UTF-8",
                    "TMPDIR" to "/tmp",
                    "TMP" to "/tmp",
                    "TEMP" to "/tmp",
                    "DEBIAN_FRONTEND" to "noninteractive",
                    "DEBCONF_NONINTERACTIVE_SEEN" to "true",
                    "LD_LIBRARY_PATH" to "${libSymlinkDir.absolutePath}:${binDir.absolutePath}",
                    "PROOT_LOADER" to stagedLoader.absolutePath,
                    "PROOT_TMP_DIR" to context.cacheDir.absolutePath
                )
            )
            val process = pb.start()
            val finished = process.waitFor(timeoutMs, TimeUnit.MILLISECONDS)
            val stdout = process.inputStream.bufferedReader().readText()
            val stderr = process.errorStream.bufferedReader().readText()
            if (!finished) {
                process.destroyForcibly()
                return@withContext mapOf(
                    "success" to false,
                    "exit_code" to -1,
                    "stdout" to stdout,
                    "stderr" to stderr,
                    "message" to "Command timed out after ${timeoutMs}ms."
                )
            }
            mapOf(
                "success" to (process.exitValue() == 0),
                "exit_code" to process.exitValue(),
                "stdout" to stdout,
                "stderr" to stderr,
                "message" to ""
            )
        } catch (e: Exception) {
            commandFail("Command execution failed: ${e.message ?: e.javaClass.simpleName}")
        }
    }

    private fun linkerPath(): String {
        return if (Build.SUPPORTED_64_BIT_ABIS.any { it == "arm64-v8a" }) {
            "/system/bin/linker64"
        } else {
            "/system/bin/linker"
        }
    }

    /**
     * Install a plugin: runs its install command as root (the proot session
     * runs as fake-root by default). Long timeout for big toolchains.
     */
    suspend fun installPlugin(
        pluginId: String,
        installCommand: String,
        timeoutMs: Long
    ): Map<String, Any?> {
        Log.d(TAG, "Installing plugin: $pluginId")
        return runCommand(installCommand, timeoutMs)
    }

    private fun fail(message: String): Map<String, Any?> {
        status = STATUS_ERROR
        lastMessage = message
        return snapshot()
    }

    private fun commandFail(message: String): Map<String, Any?> = mapOf(
        "success" to false,
        "exit_code" to -1,
        "stdout" to "",
        "stderr" to "",
        "message" to message
    )

    /**
     * Minimal tar.gz extractor. Supports regular files, directories, and
     * symlinks (typical for a Linux rootfs). No external dependency.
     */
    @Throws(IOException::class)
    private fun extractTarGz(tarGz: File, target: File) {
        GZIPInputStream(tarGz.inputStream().buffered()).use { gz ->
            extractTar(gz, target)
        }
    }

    @Throws(IOException::class)
    private fun extractTar(input: InputStream, target: File) {
        input.buffered().use { gz ->
            val header = ByteArray(512)
            while (true) {
                val read = readFully(gz, header)
                if (read < 512) break
                if (header.all { it == 0.toByte() }) continue

                val name = parseName(header)
                if (name.isEmpty()) continue
                if (name.contains("PaxHeaders")) {
                    val sz = if (String(header, 124, 12).trim().trim(' ').isEmpty()) 0L
                             else String(header, 124, 12).trim().trim(' ').toLong(8)
                    skipBytes(gz, paddedSize(sz))
                    continue
                }

                val sizeOctal = String(header, 124, 12).trim().trim('\u0000')
                val size = if (sizeOctal.isEmpty()) 0L else sizeOctal.toLong(8)
                val typeFlag = header[156].toInt().toChar()
                val linkName = String(header, 157, 100).trimEnd('\u0000')

                val outPath = File(target, name)
                // Path traversal guard.
                if (!outPath.canonicalPath.startsWith(target.canonicalPath)) {
                    skipBytes(gz, paddedSize(size))
                    continue
                }

                when (typeFlag) {
                    'x', 'g' -> {
                        // PAX extended headers — skip, don't extract.
                        skipBytes(gz, paddedSize(size))
                    }
                    '5' -> outPath.mkdirs()
                    '2' -> {
                        outPath.parentFile?.mkdirs()
                        try {
                            if (outPath.exists()) outPath.delete()
                            java.nio.file.Files.createSymbolicLink(
                                outPath.toPath(),
                                java.io.File(linkName).toPath()
                            )
                        } catch (_: Exception) {
                            // Some filesystems disallow symlinks; ignore.
                        }
                    }
                    '1' -> {
                        outPath.parentFile?.mkdirs()
                        val source = File(target, linkName)
                        try {
                            if (outPath.exists()) outPath.delete()
                            java.nio.file.Files.createLink(
                                outPath.toPath(),
                                source.toPath()
                            )
                        } catch (_: Exception) {
                            if (source.exists()) {
                                source.copyTo(outPath, overwrite = true)
                            }
                        }
                    }
                    else -> {
                        outPath.parentFile?.mkdirs()
                        FileOutputStream(outPath).use { out ->
                            copyN(gz, out, size)
                        }
                        // Set executable bit if any exec bit set in mode.
                        val modeOctal = String(header, 100, 8).trim().trim('\u0000')
                        val mode = if (modeOctal.isEmpty()) 0 else modeOctal.toInt(8)
                        if ((mode and 0b001_001_001) != 0) {
                            outPath.setExecutable(true, false)
                        }
                    }
                }
                if (typeFlag != '5' && typeFlag != '2' && typeFlag != '1' && typeFlag != 'x' && typeFlag != 'g') {
                    val padding = paddedSize(size) - size
                    skipBytes(gz, padding)
                }
            }
        }
    }

    private fun paddedSize(size: Long): Long {
        val rem = size % 512
        return if (rem == 0L) size else size + (512 - rem)
    }

    @Throws(IOException::class)
    private fun readFully(input: java.io.InputStream, buffer: ByteArray): Int {
        var total = 0
        while (total < buffer.size) {
            val n = input.read(buffer, total, buffer.size - total)
            if (n < 0) break
            total += n
        }
        return total
    }

    @Throws(IOException::class)
    private fun copyN(input: java.io.InputStream, output: FileOutputStream, n: Long) {
        val buf = ByteArray(64 * 1024)
        var remaining = n
        while (remaining > 0) {
            val toRead = if (remaining > buf.size) buf.size else remaining.toInt()
            val r = input.read(buf, 0, toRead)
            if (r < 0) break
            output.write(buf, 0, r)
            remaining -= r
        }
    }

    @Throws(IOException::class)
    private fun skipBytes(input: java.io.InputStream, n: Long) {
        var remaining = n
        val buf = ByteArray(8 * 1024)
        while (remaining > 0) {
            val toRead = if (remaining > buf.size) buf.size else remaining.toInt()
            val r = input.read(buf, 0, toRead)
            if (r < 0) break
            remaining -= r
        }
    }

    private fun parseName(header: ByteArray): String {
        // Standard 100-byte name plus 155-byte prefix at offset 345 (ustar).
        val name = String(header, 0, 100).trimEnd('\u0000', ' ')
        val magic = String(header, 257, 6)
        if (magic.startsWith("ustar")) {
            val prefix = String(header, 345, 155).trimEnd('\u0000', ' ')
            if (prefix.isNotEmpty()) return "$prefix/$name"
        }
        return name
    }

    companion object {
        private const val TAG = "VmRuntime"

        const val STATUS_UNKNOWN = "unknown"
        const val STATUS_UNAVAILABLE = "unavailable"
        const val STATUS_NOT_INSTALLED = "not_installed"
        const val STATUS_DOWNLOADING = "downloading"
        const val STATUS_INSTALLED = "installed"
        const val STATUS_STARTING = "starting"
        const val STATUS_RUNNING = "running"
        const val STATUS_STOPPED = "stopped"
        const val STATUS_ERROR = "error"

        @Volatile
        private var instance: VmRuntimeManager? = null

        fun get(context: Context): VmRuntimeManager {
            return instance ?: synchronized(this) {
                instance ?: VmRuntimeManager(context.applicationContext).also {
                    instance = it
                }
            }
        }
    }
}
