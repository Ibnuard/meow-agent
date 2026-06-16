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
import java.net.InetSocketAddress
import java.net.Socket
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
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

    /// Long-running servers spawned via [startServer]. Each one is a DEDICATED
    /// proot child process (NOT routed through the persistent session shell)
    /// so it is not coupled to session-command lifetimes — that's exactly what
    /// would let `nohup ... &` from inside the session get reaped on the next
    /// command. Indexed by caller-supplied name; native side is the source of
    /// truth for liveness.
    private data class ManagedServer(
        val name: String,
        val port: Int,
        val command: String,
        val cwd: String,
        val logPath: String,
        val process: Process,
        val startedAt: Long,
    )

    private val servers = ConcurrentHashMap<String, ManagedServer>()

    private val rootfsDir: File
        get() = File(context.filesDir, "vm-runtime/rootfs")

    private val workspaceDir: File
        get() = File(context.filesDir, "vm-runtime/workspace")

    private val downloadDir: File
        get() = File(context.filesDir, "vm-runtime/downloads")

    /// Public MeowAgent root on shared storage. This is where the files module
    /// (`files.create`) writes agent workspace files — a DIFFERENT filesystem
    /// from the VM's internal [workspaceDir]. We bind-mount it INTO the proot
    /// guest at [GUEST_MEOW_DIR] so the agent can serve/read those files from
    /// inside the VM without copying. Static reads/serves work fine over the
    /// shared-storage FUSE; heavy build work (npm/bun install, git) must stay
    /// in [workspaceDir] (internal ext4) because FUSE has no symlink support.
    private val meowSharedDir: File
        get() = File(
            android.os.Environment.getExternalStoragePublicDirectory(
                android.os.Environment.DIRECTORY_DOCUMENTS
            ),
            "MeowAgent"
        )

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
            // Host path — used by the UI file browser, NOT valid inside the VM.
            "workspace_path" to workspaceDir.absolutePath,
            // IN-GUEST paths — these are the ones a shell command must use.
            // vm_working_dir: internal ext4, safe for installs/builds/git.
            // agent_files_dir: the agent's shared workspace (where files.create
            // writes), bind-mounted in so the VM can read/serve those files.
            "vm_working_dir" to GUEST_WORKSPACE_DIR,
            "agent_files_dir" to GUEST_MEOW_DIR,
            "agent_files_available" to meowSharedDir.exists(),
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

    /// Build the optional MeowAgent shared-dir bind args for proot. Empty when
    /// the public dir doesn't exist yet (no agent files written) — proot would
    /// reject a bind of a missing host path. The dir is created lazily by the
    /// files module on first write; we attempt mkdirs() so a serve right after
    /// install still gets the mount.
    private fun meowBindArgs(): Array<String> {
        return try {
            val dir = meowSharedDir
            if (!dir.exists()) dir.mkdirs()
            if (dir.exists()) {
                arrayOf("-b", "${dir.absolutePath}:$GUEST_MEOW_DIR")
            } else {
                emptyArray()
            }
        } catch (_: Exception) {
            emptyArray()
        }
    }

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
                "-b", "${workspaceDir.absolutePath}:$GUEST_WORKSPACE_DIR",
                *meowBindArgs(),
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
                    "-b", "${workspaceDir.absolutePath}:$GUEST_WORKSPACE_DIR",
                    *meowBindArgs(),
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

    suspend fun startServer(
        name: String,
        command: String,
        cwd: String,
        port: Int,
        readyTimeoutMs: Long,
        readyPath: String = "/",
        expectedText: String = ""
    ): Map<String, Any?> = withContext(Dispatchers.IO) {
        if (name.isBlank()) return@withContext serverFail(name, port, "Server name is required.")
        if (command.isBlank()) return@withContext serverFail(name, port, "Command is required.")
        if (port <= 0 || port > 65535) return@withContext serverFail(name, port, "Invalid port: $port")
        if (!isRootfsInstalled()) return@withContext serverFail(name, port, "Runtime is not installed.")
        if (!binariesInstalled) {
            try { mutex.withLock { ensureBinariesInstalled { } } }
            catch (e: Exception) { return@withContext serverFail(name, port, "Runtime binary could not be staged: ${e.message}") }
        }

        stopServer(name)
        configureRootfs()
        workspaceDir.mkdirs()
        val shellPath = shellPathInsideRootfs()
            ?: return@withContext serverFail(name, port, "Runtime shell was not found in rootfs.")
        val logDir = File(context.filesDir, "vm-runtime/server-logs").apply { mkdirs() }
        val safe = name.replace(Regex("[^A-Za-z0-9_.-]+"), "_").ifBlank { "server" }
        val logFile = File(logDir, "$safe.log")
        if (logFile.exists()) logFile.delete()

        val workDir = cwd.ifBlank { GUEST_WORKSPACE_DIR }
        val wrapped = "cd ${shellQuote(workDir)} && exec $command"
        val pb = ProcessBuilder(
            listOf(
                linkerPath(), stagedProot.absolutePath,
                "-0", "--link2symlink", "--kill-on-exit",
                "-r", rootfsDir.absolutePath,
                "-w", "/root",
                "-b", "/dev", "-b", "/proc", "-b", "/sys",
                "-b", "${workspaceDir.absolutePath}:$GUEST_WORKSPACE_DIR",
                *meowBindArgs(),
                shellPath, "-c", wrapped,
            )
        )
        pb.environment().putAll(prootEnv())
        pb.redirectErrorStream(true)
        pb.redirectOutput(ProcessBuilder.Redirect.appendTo(logFile))

        return@withContext try {
            val process = pb.start()
            val server = ManagedServer(name, port, command, workDir, logFile.absolutePath, process, System.currentTimeMillis())
            servers[name] = server
            val path = normalizeReadyPath(readyPath)
            val deadline = System.currentTimeMillis() + readyTimeoutMs.coerceAtLeast(1000)
            var lastCheck = ""
            while (System.currentTimeMillis() < deadline) {
                if (!process.isAlive) {
                    servers.remove(name)
                    return@withContext serverFail(name, port, "Server process exited before readiness check passed.", logFile)
                }
                val check = checkHttpReady(port, path, expectedText)
                lastCheck = check["message"]?.toString() ?: ""
                if (check["ready"] == true) {
                    return@withContext serverResult(
                        server,
                        true,
                        "Server is ready.",
                        path,
                        expectedText,
                        check
                    )
                }
                Thread.sleep(300)
            }
            if (!process.isAlive) {
                servers.remove(name)
                return@withContext serverFail(name, port, "Server process exited before readiness check passed.", logFile)
            }
            serverResult(
                server,
                false,
                "Server started but readiness check failed before timeout: $lastCheck",
                path,
                expectedText,
                mapOf("message" to lastCheck)
            )
        } catch (e: Exception) {
            serverFail(name, port, "Failed to start server: ${e.message ?: e.javaClass.simpleName}", logFile)
        }
    }

    suspend fun stopServer(name: String): Map<String, Any?> = withContext(Dispatchers.IO) {
        val server = servers.remove(name)
            ?: return@withContext mapOf("success" to true, "stopped" to false, "name" to name, "message" to "No tracked server named $name.")
        try { server.process.destroy() } catch (_: Exception) {}
        try { server.process.waitFor(1500, TimeUnit.MILLISECONDS) } catch (_: Exception) {}
        if (server.process.isAlive) server.process.destroyForcibly()
        mapOf("success" to true, "stopped" to true, "name" to name, "port" to server.port, "message" to "Server stopped.")
    }

    fun listServers(): Map<String, Any?> {
        val entries = servers.values.map { server ->
            val alive = server.process.isAlive
            val listening = alive && isPortOpen(server.port)
            mapOf(
                "name" to server.name,
                "port" to server.port,
                "pid" to processPid(server.process),
                "alive" to alive,
                "listening" to listening,
                "url" to "http://127.0.0.1:${server.port}/",
                "cwd" to server.cwd,
                "log_path" to server.logPath,
                "started_at" to server.startedAt,
            )
        }
        return mapOf("success" to true, "servers" to entries, "count" to entries.size)
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

    private fun prootEnv(): Map<String, String> = mapOf(
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
        "PROOT_TMP_DIR" to context.cacheDir.absolutePath,
    )

    private fun shellQuote(value: String): String = "'" + value.replace("'", "'\\''") + "'"

    private fun processPid(process: Process): Long? {
        return try {
            val method = Process::class.java.methods.firstOrNull { it.name == "pid" && it.parameterTypes.isEmpty() }
            (method?.invoke(process) as? Long)
        } catch (_: Exception) {
            null
        }
    }

    private fun normalizeReadyPath(path: String): String {
        val trimmed = path.trim().ifEmpty { "/" }
        return if (trimmed.startsWith("/")) trimmed else "/$trimmed"
    }

    private fun isPortOpen(port: Int): Boolean {
        return try {
            Socket().use { socket ->
                socket.connect(InetSocketAddress("127.0.0.1", port), 300)
                true
            }
        } catch (_: Exception) {
            false
        }
    }

    private fun checkHttpReady(port: Int, path: String, expectedText: String): Map<String, Any?> {
        val url = "http://127.0.0.1:$port$path"
        return try {
            Socket().use { socket ->
                socket.connect(InetSocketAddress("127.0.0.1", port), 500)
                socket.soTimeout = 1000
                val out = socket.getOutputStream().bufferedWriter()
                out.write("GET $path HTTP/1.1\r\n")
                out.write("Host: 127.0.0.1:$port\r\n")
                out.write("Connection: close\r\n")
                out.write("User-Agent: MeowVmRuntime/1\r\n")
                out.write("\r\n")
                out.flush()
                val raw = socket.getInputStream().bufferedReader().use { it.readText().take(8192) }
                val statusLine = raw.lineSequence().firstOrNull().orEmpty()
                val code = Regex("HTTP/\\d(?:\\.\\d)?\\s+(\\d{3})").find(statusLine)
                    ?.groupValues?.getOrNull(1)?.toIntOrNull() ?: -1
                val okStatus = code in 200..399
                val body = raw.substringAfter("\r\n\r\n", raw.substringAfter("\n\n", ""))
                val expectedOk = expectedText.isBlank() || body.contains(expectedText, ignoreCase = true)
                mapOf(
                    "ready" to (okStatus && expectedOk),
                    "http_status" to code,
                    "url" to url,
                    "expected_text" to expectedText,
                    "expected_text_found" to expectedOk,
                    "body_snippet" to body.take(500),
                    "message" to when {
                        !okStatus -> "HTTP $code from $url"
                        !expectedOk -> "HTTP $code but expected text was not found at $url"
                        else -> "HTTP $code ready at $url"
                    }
                )
            }
        } catch (e: Exception) {
            mapOf(
                "ready" to false,
                "url" to url,
                "message" to (e.message ?: e.javaClass.simpleName)
            )
        }
    }

    private fun serverResult(
        server: ManagedServer,
        listening: Boolean,
        message: String,
        readyPath: String = "/",
        expectedText: String = "",
        readiness: Map<String, Any?> = emptyMap()
    ): Map<String, Any?> {
        return mapOf(
            "success" to listening,
            "name" to server.name,
            "port" to server.port,
            "pid" to processPid(server.process),
            "alive" to server.process.isAlive,
            "listening" to listening,
            "url" to "http://127.0.0.1:${server.port}$readyPath",
            "ready_path" to readyPath,
            "expected_text" to expectedText,
            "readiness" to readiness,
            "cwd" to server.cwd,
            "log_path" to server.logPath,
            "log_tail" to readTail(File(server.logPath)),
            "message" to message,
        )
    }

    private fun serverFail(name: String, port: Int, message: String, logFile: File? = null): Map<String, Any?> {
        return mapOf(
            "success" to false,
            "name" to name,
            "port" to port,
            "listening" to false,
            "message" to message,
            "log_tail" to readTail(logFile),
        )
    }

    private fun readTail(file: File?): String {
        return try {
            if (file == null || !file.exists()) return ""
            val lines = file.readLines()
            lines.takeLast(80).joinToString("\n")
        } catch (_: Exception) {
            ""
        }
    }

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

        /// In-guest mount point for the VM's internal working dir (ext4 —
        /// safe for builds, installs, git).
        const val GUEST_WORKSPACE_DIR = "/root/workspace"

        /// In-guest mount point for the public MeowAgent shared dir (where the
        /// files module writes agent workspace files). Read/serve static files
        /// from here; do NOT run installs/git here (FUSE has no symlinks).
        const val GUEST_MEOW_DIR = "/root/meow"

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
