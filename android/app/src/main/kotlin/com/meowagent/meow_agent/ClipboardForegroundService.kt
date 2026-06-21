package com.meowagent.meow_agent

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

class ClipboardForegroundService : Service() {

    companion object {
        const val CHANNEL_ID = "meow_clipboard_channel"
        const val NOTIFICATION_ID = 1001
        const val ACTION_PROCESS = "com.meowagent.ACTION_PROCESS_CLIPBOARD"
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_PROCESS) {
            processClipboard()
            return START_STICKY
        }

        val notification = buildNotification()
        startForeground(NOTIFICATION_ID, notification)
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Clipboard Quick Action",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Keeps a button ready to process the current clipboard text"
                setShowBadge(false)
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        // Intent to process clipboard when notification action is tapped.
        val processIntent = Intent(this, MainActivity::class.java).apply {
            action = ACTION_PROCESS
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val processPending = PendingIntent.getActivity(
            this, 0, processIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Clipboard Quick Action")
            .setContentText("Tap to process the current clipboard text with Meow Agent")
            .setSmallIcon(android.R.drawable.ic_menu_edit)
            .setOngoing(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .addAction(
                android.R.drawable.ic_menu_send,
                "Process Clipboard",
                processPending
            )
            .setContentIntent(processPending)
            .build()
    }

    private fun processClipboard() {
        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val clip = clipboard.primaryClip
        if (clip != null && clip.itemCount > 0) {
            val text = clip.getItemAt(0).text?.toString()
            if (!text.isNullOrBlank()) {
                val intent = Intent(this, MainActivity::class.java).apply {
                    action = ACTION_PROCESS
                    putExtra("clipboard_text", text)
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
                }
                startActivity(intent)
            }
        }
    }
}
