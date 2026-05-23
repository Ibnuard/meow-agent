package com.meowagent.meow_agent

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.PixelFormat
import android.os.Build
import android.os.IBinder
import android.util.Log
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageView
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import kotlin.math.abs

/// Foreground service that shows a draggable floating bubble overlay.
/// Tapping the bubble launches MainActivity, which reads the clipboard.
class FloatingBubbleService : Service() {

    private val TAG = "MeowBubble"
    private var windowManager: WindowManager? = null
    private var bubbleView: View? = null
    private var layoutParams: WindowManager.LayoutParams? = null

    companion object {
        const val CHANNEL_ID = "meow_bubble_channel"
        const val NOTIFICATION_ID = 1002
        const val ACTION_STOP = "com.meowagent.STOP_BUBBLE"
    }

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "Service onCreate")
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }

        startForeground(NOTIFICATION_ID, buildNotification())
        showBubble()
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        super.onDestroy()
        Log.d(TAG, "Service onDestroy")
        removeBubble()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Meow Bubble",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Floating bubble for quick clipboard processing"
                setShowBadge(false)
            }
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val stopIntent = Intent(this, FloatingBubbleService::class.java).apply {
            action = ACTION_STOP
        }
        val stopPending = PendingIntent.getService(
            this, 0, stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Meow Bubble Active")
            .setContentText("Floating bubble is running")
            .setSmallIcon(android.R.drawable.ic_menu_view)
            .setOngoing(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Stop", stopPending)
            .build()
    }

    private fun showBubble() {
        if (bubbleView != null) return
        Log.d(TAG, "Showing bubble")

        windowManager = getSystemService(Context.WINDOW_SERVICE) as WindowManager

        // Inflate the bubble view programmatically.
        val container = FrameLayout(this).apply {
            background =
                ContextCompat.getDrawable(this@FloatingBubbleService, R.drawable.bubble_background)
            elevation = 12f
        }

        val icon = ImageView(this).apply {
            setImageResource(android.R.drawable.ic_menu_edit)
            setColorFilter(android.graphics.Color.WHITE)
            val padding = (12 * resources.displayMetrics.density).toInt()
            setPadding(padding, padding, padding, padding)
        }
        container.addView(icon)

        val sizePx = (52 * resources.displayMetrics.density).toInt()

        layoutParams = WindowManager.LayoutParams(
            sizePx,
            sizePx,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            else
                @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = (resources.displayMetrics.widthPixels - sizePx - 24)
            y = (resources.displayMetrics.heightPixels / 3)
        }

        attachDragAndTap(container)

        try {
            windowManager?.addView(container, layoutParams)
            bubbleView = container
        } catch (e: Exception) {
            Log.e(TAG, "Failed to add bubble view", e)
        }
    }

    private fun attachDragAndTap(view: View) {
        var initialX = 0
        var initialY = 0
        var touchX = 0f
        var touchY = 0f
        var isDragging = false
        val tapThreshold = 8 * resources.displayMetrics.density

        view.setOnTouchListener { v, event ->
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    initialX = layoutParams?.x ?: 0
                    initialY = layoutParams?.y ?: 0
                    touchX = event.rawX
                    touchY = event.rawY
                    isDragging = false
                    true
                }

                MotionEvent.ACTION_MOVE -> {
                    val dx = event.rawX - touchX
                    val dy = event.rawY - touchY
                    if (!isDragging && (abs(dx) > tapThreshold || abs(dy) > tapThreshold)) {
                        isDragging = true
                    }
                    if (isDragging) {
                        layoutParams?.x = initialX + dx.toInt()
                        layoutParams?.y = initialY + dy.toInt()
                        windowManager?.updateViewLayout(view, layoutParams)
                    }
                    true
                }

                MotionEvent.ACTION_UP -> {
                    if (!isDragging) {
                        // Treat as tap.
                        v.performClick()
                        launchProcess()
                    } else {
                        // Snap to nearest edge.
                        snapToEdge()
                    }
                    true
                }

                else -> false
            }
        }
    }

    private fun snapToEdge() {
        val params = layoutParams ?: return
        val view = bubbleView ?: return
        val screenWidth = resources.displayMetrics.widthPixels
        val bubbleWidth = view.width
        val mid = screenWidth / 2

        params.x = if (params.x + bubbleWidth / 2 < mid) {
            8
        } else {
            screenWidth - bubbleWidth - 8
        }
        windowManager?.updateViewLayout(view, params)
    }

    private fun launchProcess() {
        Log.d(TAG, "Bubble tapped — launching MainActivity")
        val intent = Intent(this, MainActivity::class.java).apply {
            action = ClipboardForegroundService.ACTION_PROCESS
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        startActivity(intent)
    }

    private fun removeBubble() {
        bubbleView?.let {
            try {
                windowManager?.removeView(it)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to remove bubble", e)
            }
        }
        bubbleView = null
    }
}
