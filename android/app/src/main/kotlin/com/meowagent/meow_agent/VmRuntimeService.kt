package com.meowagent.meow_agent

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * Foreground service that owns the lifetime of long-running VM operations
 * (rootfs download, plugin install, dev server). Without an FGS, Android may
 * kill these jobs mid-flight on doze or memory pressure.
 *
 * The service itself does not run proot — proot runs as a child process from
 * [VmRuntimeManager]. The service exists purely to keep the app process
 * alive long enough for those operations to complete.
 */
class VmRuntimeService : Service() {

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "VM Runtime"
        val text = intent?.getStringExtra(EXTRA_TEXT)
            ?: "Local Linux runtime is active."
        val notification = buildNotification(title, text)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "VM Runtime",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Keeps the local Linux runtime alive during long operations"
                setShowBadge(false)
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(title: String, text: String): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_menu_manage)
            .setOngoing(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    companion object {
        const val CHANNEL_ID = "meow_vm_runtime_channel"
        const val NOTIFICATION_ID = 1101
        const val EXTRA_TITLE = "extra_title"
        const val EXTRA_TEXT = "extra_text"
    }
}
