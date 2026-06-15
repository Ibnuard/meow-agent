package com.meowagent.meow_agent

import android.content.Context
import android.content.Intent
import android.os.Build
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Method-channel handler for `com.meowagent/vm_runtime`.
 *
 * Bridges Dart calls (status/downloadRootfs/start/stop/runCommand/
 * installPlugin/probePlugin) to [VmRuntimeManager].
 */
class VmRuntimePlugin(private val context: Context) :
    MethodChannel.MethodCallHandler {

    private val manager = VmRuntimeManager.get(context)
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "status" -> {
                result.success(manager.snapshot())
            }
            "downloadRootfs" -> {
                val url = call.argument<String>("url") ?: ""
                val sha256 = call.argument<String>("sha256") ?: ""
                val version = call.argument<String>("version") ?: "ubuntu-minimal"
                if (url.isBlank()) {
                    result.success(
                        manager.snapshot() + mapOf(
                            "status" to "error",
                            "message" to "Missing rootfs URL."
                        )
                    )
                    return
                }
                startService("Installing runtime", "Downloading rootfs...")
                scope.launch {
                    val snapshot = manager.downloadRootfs(url, sha256, version) { stage ->
                        updateNotification("Installing runtime", stage)
                    }
                    val success = snapshot["status"] != "error"
                    if (success) {
                        updateNotification("VM Runtime", "Runtime siap digunakan.")
                    } else {
                        updateNotification("VM Runtime", "Gagal install runtime.")
                    }
                    withContext(Dispatchers.Main) { result.success(snapshot) }
                    // Keep completion notification visible briefly before stopping.
                    kotlinx.coroutines.delay(3000)
                    stopService()
                }
            }
            "start" -> {
                startService("VM Runtime", "Sesi Linux aktif.")
                scope.launch {
                    val snapshot = manager.start()
                    withContext(Dispatchers.Main) { result.success(snapshot) }
                    // Keep FGS alive — don't stop it here.
                }
            }
            "stop" -> {
                scope.launch {
                    val snapshot = manager.stop()
                    stopService()
                    withContext(Dispatchers.Main) { result.success(snapshot) }
                }
            }
            "runCommand" -> {
                val command = call.argument<String>("command") ?: ""
                val timeout = (call.argument<Int>("timeout_ms") ?: 60_000).toLong()
                scope.launch {
                    val payload = manager.runCommand(command, timeout)
                    withContext(Dispatchers.Main) { result.success(payload) }
                }
            }
            "installPlugin" -> {
                val pluginId = call.argument<String>("plugin_id") ?: ""
                val installCommand = call.argument<String>("install_command") ?: ""
                val timeout = (call.argument<Int>("timeout_ms") ?: 600_000).toLong()
                if (pluginId.isBlank() || installCommand.isBlank()) {
                    result.success(
                        mapOf(
                            "success" to false,
                            "exit_code" to -1,
                            "stdout" to "",
                            "stderr" to "",
                            "message" to "plugin_id and install_command are required."
                        )
                    )
                    return
                }
                startService("Installing $pluginId", "This may take a few minutes.")
                scope.launch {
                    val payload = manager.installPlugin(pluginId, installCommand, timeout)
                    val success = payload["success"] as? Boolean ?: false
                    if (success) {
                        updateNotification("Plugin Installed", "$pluginId berhasil dipasang.")
                    } else {
                        updateNotification("Plugin Failed", "Gagal memasang $pluginId.")
                    }
                    withContext(Dispatchers.Main) { result.success(payload) }
                    kotlinx.coroutines.delay(3000)
                    stopService()
                }
            }
            "probePlugin" -> {
                val versionCommand = call.argument<String>("version_command") ?: ""
                val timeout = (call.argument<Int>("timeout_ms") ?: 5_000).toLong()
                scope.launch {
                    val payload = manager.runCommand(versionCommand, timeout)
                    withContext(Dispatchers.Main) { result.success(payload) }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun startService(title: String, text: String) {
        val intent = Intent(context, VmRuntimeService::class.java).apply {
            putExtra(VmRuntimeService.EXTRA_TITLE, title)
            putExtra(VmRuntimeService.EXTRA_TEXT, text)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(intent)
        } else {
            context.startService(intent)
        }
    }

    private fun updateNotification(title: String, text: String) {
        // Restart the service with new extras; the FGS reuses the same id so
        // the notification just updates.
        startService(title, text)
    }

    private fun stopService() {
        context.stopService(Intent(context, VmRuntimeService::class.java))
    }

    companion object {
        const val CHANNEL = "com.meowagent/vm_runtime"
    }
}
