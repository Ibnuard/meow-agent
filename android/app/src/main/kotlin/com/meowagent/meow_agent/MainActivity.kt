package com.meowagent.meow_agent

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val SHARE_CHANNEL = "com.meowagent/share"
    private val SERVICE_CHANNEL = "com.meowagent/services"
    private var sharedText: String? = null
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var shareChannel: MethodChannel? = null
    private val TAG = "MeowAgent"

    companion object {
        const val NOTIFICATION_PERMISSION_CODE = 1001
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        Log.d(TAG, "configureFlutterEngine called")

        shareChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SHARE_CHANNEL)
        shareChannel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "getSharedText" -> {
                    Log.d(TAG, "getSharedText called, returning: $sharedText")
                    result.success(sharedText)
                    sharedText = null
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SERVICE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startNotificationService" -> {
                        startClipboardService()
                        result.success(true)
                    }
                    "stopNotificationService" -> {
                        stopClipboardService()
                        result.success(true)
                    }
                    "isNotificationServiceRunning" -> {
                        result.success(isServiceRunning(ClipboardForegroundService::class.java))
                    }
                    "requestNotificationPermission" -> {
                        requestNotificationPermission(result)
                    }
                    "startBubbleService" -> {
                        startBubbleService()
                        result.success(true)
                    }
                    "stopBubbleService" -> {
                        stopBubbleService()
                        result.success(true)
                    }
                    "isBubbleServiceRunning" -> {
                        result.success(isServiceRunning(FloatingBubbleService::class.java))
                    }
                    "canDrawOverlays" -> {
                        result.success(canDrawOverlays())
                    }
                    "requestOverlayPermission" -> {
                        requestOverlayPermission()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        if (sharedText != null) {
            val text = sharedText
            Handler(Looper.getMainLooper()).postDelayed({
                Log.d(TAG, "Pushing pending sharedText after engine ready: $text")
                shareChannel?.invokeMethod("onSharedText", text)
                sharedText = null
            }, 300)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Log.d(TAG, "onCreate, action=${intent?.action}")
        handleIncomingIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        Log.d(TAG, "onNewIntent, action=${intent.action}")
        setIntent(intent)
        handleIncomingIntent(intent)
        if (sharedText != null) {
            val text = sharedText
            sharedText = null
            Handler(Looper.getMainLooper()).postDelayed({
                Log.d(TAG, "Pushing onSharedText to Flutter: $text")
                shareChannel?.invokeMethod("onSharedText", text)
            }, 200)
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        Log.d(TAG, "onWindowFocusChanged, hasFocus=$hasFocus, sharedText=$sharedText, intentAction=${intent?.action}")
        if (hasFocus && sharedText == null && intent != null) {
            val action = intent.action
            if (action == ClipboardForegroundService.ACTION_PROCESS) {
                intent.action = null
                Handler(Looper.getMainLooper()).postDelayed({
                    Log.d(TAG, "Retrying clipboard read after focus")
                    readClipboard()
                    if (sharedText != null) {
                        val text = sharedText
                        sharedText = null
                        Log.d(TAG, "Pushing delayed onSharedText: $text")
                        shareChannel?.invokeMethod("onSharedText", text)
                    }
                }, 300)
            }
        }
    }

    private fun handleIncomingIntent(intent: Intent?) {
        if (intent == null) return

        when {
            intent.action == Intent.ACTION_SEND && intent.type == "text/plain" -> {
                sharedText = intent.getStringExtra(Intent.EXTRA_TEXT)
                Log.d(TAG, "Received SEND intent, text length=${sharedText?.length}")
            }
            intent.action == ClipboardForegroundService.ACTION_PROCESS -> {
                val clipText = intent.getStringExtra("clipboard_text")
                if (!clipText.isNullOrBlank()) {
                    sharedText = clipText
                    Log.d(TAG, "Received intent with clipboard_text extra, length=${clipText.length}")
                } else {
                    Log.d(TAG, "Intent without clipboard_text — reading from system clipboard")
                    readClipboard()
                }
            }
        }
    }

    private fun readClipboard() {
        val clipboard = getSystemService(CLIPBOARD_SERVICE) as android.content.ClipboardManager
        val clip = clipboard.primaryClip
        if (clip != null && clip.itemCount > 0) {
            val text = clip.getItemAt(0).text?.toString()
            if (!text.isNullOrBlank()) {
                sharedText = text
                Log.d(TAG, "Read clipboard, length=${text.length}")
            } else {
                Log.d(TAG, "Clipboard empty or non-text")
            }
        } else {
            Log.d(TAG, "No primary clip")
        }
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
                == PackageManager.PERMISSION_GRANTED
            ) {
                result.success(true)
            } else {
                pendingPermissionResult = result
                ActivityCompat.requestPermissions(
                    this,
                    arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                    NOTIFICATION_PERMISSION_CODE
                )
            }
        } else {
            result.success(true)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == NOTIFICATION_PERMISSION_CODE) {
            val granted = grantResults.isNotEmpty() &&
                    grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingPermissionResult?.success(granted)
            pendingPermissionResult = null
        }
    }

    private fun startClipboardService() {
        val serviceIntent = Intent(this, ClipboardForegroundService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(serviceIntent)
        } else {
            startService(serviceIntent)
        }
    }

    private fun stopClipboardService() {
        stopService(Intent(this, ClipboardForegroundService::class.java))
    }

    private fun startBubbleService() {
        val serviceIntent = Intent(this, FloatingBubbleService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(serviceIntent)
        } else {
            startService(serviceIntent)
        }
    }

    private fun stopBubbleService() {
        stopService(Intent(this, FloatingBubbleService::class.java))
    }

    private fun canDrawOverlays(): Boolean {
        return Settings.canDrawOverlays(this)
    }

    private fun requestOverlayPermission() {
        val intent = Intent(
            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
            Uri.parse("package:$packageName")
        ).apply { flags = Intent.FLAG_ACTIVITY_NEW_TASK }
        startActivity(intent)
    }

    private fun isServiceRunning(serviceClass: Class<*>): Boolean {
        val manager = getSystemService(ACTIVITY_SERVICE) as android.app.ActivityManager
        @Suppress("DEPRECATION")
        for (service in manager.getRunningServices(Int.MAX_VALUE)) {
            if (service.service.className == serviceClass.name) {
                return true
            }
        }
        return false
    }
}
