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

    // @Volatile so the UI can poll snapshot() during a long-running download
    // (which holds the mutex). The lock is only for serialising operations,
    // not for reads.
    @Volatile private var status: String = STATUS_UNKNOWN
    @Volatile private var lastMessage: String = ""
    @Volatile private var runtimeVersion: String = ""

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
        // Proot is invoked per-command, but we keep a "service running" flag so
        // the UI reflects intent. A future iteration may keep a long-lived
        // session via a PTY.
        status = STATUS_RUNNING
        lastMessage = ""
        snapshot()
    }

    suspend fun stop(): Map<String, Any?> = mutex.withLock {
        status = STATUS_STOPPED
        lastMessage = ""
        snapshot()
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
     * Run a single shell command inside the chroot via proot.
     *
     * Returns a map with: success, exit_code, stdout, stderr, message.
     */
    suspend fun runCommand(
        command: String,
        timeoutMs: Long
    ): Map<String, Any?> = withContext(Dispatchers.IO) {
        if (!isRootfsInstalled()) {
            return@withContext commandFail("Runtime is not installed.")
        }
        // Self-heal: existing installs predating the loader fix have rootfs
        // but no loader. Re-stage the small proot/libtalloc debs (~500 KB)
        // on demand instead of forcing the user to reinstall the rootfs.
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
                    // Fake-root inside the chroot so apt/dpkg/chown/chmod
                    // succeed; without this, plugin installs fail with EPERM.
                    "-0",
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
                    // proot needs libtalloc.so.2; we staged it in binDir under
                    // that exact name so the dynamic linker resolves it.
                    "LD_LIBRARY_PATH" to "${libSymlinkDir.absolutePath}:${binDir.absolutePath}",
                    // proot's companion loader. The compile-time default
                    // points to Termux's prefix (/data/data/com.termux/...),
                    // which doesn't exist inside our app sandbox; without
                    // this override, every exec inside the chroot fails.
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
                if (typeFlag != '5' && typeFlag != '2' && typeFlag != '1') {
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
