package com.meowagent.meow_agent

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val SHARE_CHANNEL = "com.meowagent/share"
    private val SERVICE_CHANNEL = "com.meowagent/services"
    private var sharedText: String? = null
    private var shareChannel: MethodChannel? = null
    private val TAG = "MeowAgent"

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
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DeviceContextPlugin.CHANNEL)
            .setMethodCallHandler(DeviceContextPlugin(this))

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CommunicationPlugin.CHANNEL)
            .setMethodCallHandler(CommunicationPlugin(this))

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.meowagent/app_agent")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isAccessibilityEnabled" -> {
                        result.success(MeowAccessibilityService.isEnabled(this))
                    }
                    "captureScreen" -> {
                        result.success(
                            MeowAccessibilityService.captureDefaultTree()
                                ?: mapOf(
                                    "success" to false,
                                    "error" to "accessibility_service_not_connected"
                                )
                        )
                    }
                    "performAction" -> {
                        val nodeId = call.argument<Int>("node_id") ?: -1
                        val action = call.argument<String>("action") ?: ""
                        val text = call.argument<String>("text")
                        val direction = call.argument<String>("direction")
                        result.success(
                            MeowAccessibilityService.performNodeAction(
                                nodeId,
                                action,
                                text,
                                direction
                            )
                        )
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.meowagent/app_control")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openApp" -> {
                        val pkg = call.argument<String>("package") ?: ""
                        result.success(openApp(pkg))
                    }
                    "listInstalledApps" -> {
                        result.success(listInstalledApps())
                    }
                    "openSettings" -> {
                        val action = call.argument<String>("action") ?: Settings.ACTION_SETTINGS
                        openSystemSettings(action)
                        result.success(true)
                    }
                    "openUrl" -> {
                        val url = call.argument<String>("url") ?: ""
                        result.success(openUrl(url))
                    }
                    "openAppInfo" -> {
                        val pkg = call.argument<String>("package") ?: packageName
                        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                            data = Uri.parse("package:$pkg")
                            flags = Intent.FLAG_ACTIVITY_NEW_TASK
                        }
                        startActivity(intent)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        // Shizuku Shell Automation channel
        val shizukuManager = ShizukuManager(applicationContext)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.meowagent/shizuku")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getStatus" -> {
                        result.success(shizukuManager.getStatus())
                    }
                    "requestPermission" -> {
                        shizukuManager.requestPermission()
                        result.success(true)
                    }
                    "exec" -> {
                        val command = call.argument<String>("command") ?: ""
                        val shellResult = shizukuManager.exec(command)
                        result.success(shellResult.toMap())
                    }
                    "wakeScreen" -> {
                        result.success(shizukuManager.wakeScreen().toMap())
                    }
                    "isScreenOn" -> {
                        result.success(shizukuManager.isScreenOn())
                    }
                    "isDeviceLocked" -> {
                        result.success(shizukuManager.isDeviceLocked())
                    }
                    "swipeUp" -> {
                        result.success(shizukuManager.swipeUp().toMap())
                    }
                    "inputText" -> {
                        val text = call.argument<String>("text") ?: ""
                        result.success(shizukuManager.inputText(text).toMap())
                    }
                    "pressKey" -> {
                        val keycode = call.argument<Int>("keycode") ?: 0
                        result.success(shizukuManager.pressKey(keycode).toMap())
                    }
                    "tap" -> {
                        val x = call.argument<Int>("x") ?: 0
                        val y = call.argument<Int>("y") ?: 0
                        result.success(shizukuManager.tap(x, y).toMap())
                    }
                    "lockDevice" -> {
                        result.success(shizukuManager.lockDevice().toMap())
                    }
                    "wakeAndUnlock" -> {
                        val pin = call.argument<String>("pin") ?: ""
                        val unlockResult = shizukuManager.wakeAndUnlock(pin)
                        result.success(unlockResult)
                    }
                    "isAccessibilityEnabled" -> {
                        result.success(MeowAccessibilityService.isEnabled(this))
                    }
                    else -> result.notImplemented()
                }
            }

        // Bubble Chat bridge — connects FloatingBubbleService ↔ Flutter
        val bubbleChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.meowagent/bubble")
        bubbleChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "sendResponse" -> {
                    // Flutter → Bubble: deliver agent response to overlay
                    val response = call.argument<String>("response") ?: ""
                    val header = call.argument<String>("header")
                    FloatingBubbleService.deliverResponse(response, header)
                    result.success(true)
                }
                "updateChatInfo" -> {
                    // Flutter → Bubble: update header subtitle with agent/model info
                    val info = call.argument<String>("info") ?: ""
                    FloatingBubbleService.updateChatInfo(info)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // App Agent overlay bridge — full-screen border + bottom narrator bar
        // rendered while the App Agent runtime is in flight.
        val appAgentOverlayChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.meowagent/app_agent_overlay"
        )
        appAgentOverlayChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "show" -> {
                    val operation = call.argument<String>("operation")
                    val narrative = call.argument<String>("narrative") ?: ""
                    AppAgentOverlayService.show(this, operation, narrative)
                    result.success(true)
                }
                "hide" -> {
                    AppAgentOverlayService.hide(this)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // Listen for stop button press from the App Agent overlay.
        val cancelFilter = android.content.IntentFilter("com.meowagent.APP_AGENT_CANCEL")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(object : android.content.BroadcastReceiver() {
                override fun onReceive(ctx: android.content.Context, i: android.content.Intent) {
                    Handler(Looper.getMainLooper()).post {
                        appAgentOverlayChannel.invokeMethod("onStopPressed", null)
                    }
                }
            }, cancelFilter, android.content.Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(object : android.content.BroadcastReceiver() {
                override fun onReceive(ctx: android.content.Context, i: android.content.Intent) {
                    Handler(Looper.getMainLooper()).post {
                        appAgentOverlayChannel.invokeMethod("onStopPressed", null)
                    }
                }
            }, cancelFilter)
        }

        // Wire up Bubble → Flutter: when user sends message from bubble
        FloatingBubbleService.onSendMessage = { message ->
            Handler(Looper.getMainLooper()).post {
                bubbleChannel.invokeMethod("onBubbleChat", mapOf("message" to message))
            }
        }

        // Wire up Bubble → Flutter: request agent/model info when chat opens
        FloatingBubbleService.onRequestInfo = {
            Handler(Looper.getMainLooper()).post {
                bubbleChannel.invokeMethod("onRequestInfo", null)
            }
        }

        // Wire up Bubble → Flutter: cancel active task
        FloatingBubbleService.onCancelMessage = {
            Handler(Looper.getMainLooper()).post {
                bubbleChannel.invokeMethod("onCancelBubbleChat", null)
            }
        }

        val notificationsChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.meowagent/notifications")
        notificationsChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "isNotificationAccessGranted" -> {
                    result.success(isNotificationAccessGranted())
                }
                "openNotificationAccessSettings" -> {
                    openNotificationAccessSettings()
                    result.success(true)
                }
                "getRecentNotifications" -> {
                    val limit = (call.argument<Int>("limit") ?: 10).coerceIn(1, 100)
                    result.success(getRecentNotifications(limit))
                }
                "getNotificationById" -> {
                    val id = call.argument<String>("id") ?: ""
                    result.success(getNotificationById(id))
                }
                else -> result.notImplemented()
            }
        }

        // Bridge: forward each newly-posted notification to Flutter so the
        // workflow event listener can match keyword triggers in real time.
        // The listener service runs on a binder thread; hop to main before
        // invoking the channel.
        val mainHandler = Handler(Looper.getMainLooper())
        NotificationListener.onPostedCallback = { cached ->
            mainHandler.post {
                try {
                    notificationsChannel.invokeMethod("onNotificationPosted", cached.toMap())
                } catch (e: Exception) {
                    Log.w(TAG, "Failed to forward notification to Flutter: ${e.message}")
                }
            }
        }

        // Storage channel — workspace Documents path and folder opener.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.meowagent.meow_agent/storage")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getDocumentsPath" -> {
                        val docsDir = Environment.getExternalStoragePublicDirectory(
                            Environment.DIRECTORY_DOCUMENTS
                        )
                        result.success(docsDir.absolutePath)
                    }
                    "openWorkspaceFolder" -> {
                        val path = call.argument<String>("path") ?: ""
                        result.success(openFolderInFileManager(path))
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

    private fun openApp(packageName: String): Boolean {
        return try {
            val intent = packageManager.getLaunchIntentForPackage(packageName)
            if (intent != null) {
                // Required when launching from a non-Activity context, and so the
                // target app comes to the foreground when our app is backgrounded.
                intent.addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP
                )
                // Use applicationContext so the launch is not tied to MainActivity
                // lifecycle. If the activity is paused, calling startActivity on
                // `this` may be silently dropped by the system on Android 10+.
                applicationContext.startActivity(intent)
                Log.d(TAG, "Opened app: $packageName")
                true
            } else {
                Log.d(TAG, "App not found: $packageName")
                false
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to open app: $packageName", e)
            false
        }
    }

    private fun listInstalledApps(): List<Map<String, String>> {
        return try {
            val pm = packageManager
            val apps = pm.getInstalledApplications(android.content.pm.PackageManager.GET_META_DATA)
            apps
                .filter { pm.getLaunchIntentForPackage(it.packageName) != null }
                .map { app ->
                    mapOf(
                        "name" to (pm.getApplicationLabel(app).toString()),
                        "package" to app.packageName
                    )
                }
                .sortedBy { it["name"] }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to list apps", e)
            emptyList()
        }
    }

    private fun openSystemSettings(action: String) {
        try {
            val intent = Intent(action).apply {
                if (action == Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION) {
                    data = Uri.parse("package:$packageName")
                }
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }
            startActivity(intent)
            Log.d(TAG, "Opened settings: $action")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to open settings: $action", e)
            val fallbackAction = if (action == Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION) {
                Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION
            } else {
                Settings.ACTION_SETTINGS
            }
            startActivity(Intent(fallbackAction).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            })
        }
    }

    private fun openUrl(url: String): Boolean {
        return try {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }
            startActivity(intent)
            Log.d(TAG, "Opened URL: $url")
            true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to open URL: $url", e)
            false
        }
    }

    private fun openFolderInFileManager(path: String): Boolean {
        // Ensure directory exists first.
        val dir = java.io.File(path)
        if (!dir.exists()) dir.mkdirs()

        // Build the document ID in format: "primary:Documents/MeowAgent/Agents/Name"
        val relativePath = path.removePrefix("/storage/emulated/0/")
        val documentId = "primary:$relativePath"

        return try {
            // Use DocumentsContract API for proper URI encoding.
            val uri = DocumentsContract.buildDocumentUri(
                "com.android.externalstorage.documents",
                documentId
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "vnd.android.document/directory")
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }
            startActivity(intent)
            true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to open folder: $path", e)
            false
        }
    }

    // ── Notification Listener bridge ──────────────────────────────────────

    /**
     * True if the user has enabled "Notification access" for this app.
     * Cross-checked against NotificationListener.isConnected when possible.
     */
    private fun isNotificationAccessGranted(): Boolean {
        return try {
            val flat = Settings.Secure.getString(contentResolver, "enabled_notification_listeners")
                ?: return false
            val cn = "$packageName/${NotificationListener::class.java.name}"
            flat.split(":").any { it.equals(cn, ignoreCase = true) }
        } catch (e: Exception) {
            Log.w(TAG, "isNotificationAccessGranted error: ${e.message}")
            false
        }
    }

    private fun openNotificationAccessSettings() {
        try {
            val intent = Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }
            startActivity(intent)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to open notification access settings", e)
            startActivity(Intent(Settings.ACTION_SETTINGS).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            })
        }
    }

    private fun getRecentNotifications(limit: Int): List<Map<String, Any?>> {
        return try {
            NotificationListener.snapshot()
                .take(limit)
                .map { it.toMap() }
        } catch (e: Exception) {
            Log.w(TAG, "getRecentNotifications error: ${e.message}")
            emptyList()
        }
    }

    private fun getNotificationById(id: String): Map<String, Any?>? {
        if (id.isBlank()) return null
        return try {
            NotificationListener.findById(id)?.toMap()
        } catch (e: Exception) {
            Log.w(TAG, "getNotificationById error: ${e.message}")
            null
        }
    }
}
