package com.meowagent.meow_agent

import android.app.Notification
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log

/**
 * Read-only notification listener with reply capability.
 *
 * Maintains an in-memory cache (max 100) of the most recent notifications
 * posted on the device. The cache is exposed to Flutter via the channel
 * handler in [MainActivity].
 *
 * Reply support: [replyToNotification] finds a notification by key, extracts
 * the reply RemoteInput from its actions, fills it with the given text, and
 * fires the PendingIntent — delivering the reply to the correct conversation.
 */
class NotificationListener : NotificationListenerService() {
    companion object {
        private const val TAG = "MeowAgentNotif"
        private const val MAX_CACHE = 100

        @Volatile
        private var instance: NotificationListener? = null

        /**
         * Optional callback invoked whenever a notification is posted.
         * Set by [MainActivity] so it can forward the event to Flutter.
         * Survives across listener reconnects because it's static.
         */
        @Volatile
        var onPostedCallback: ((CachedNotification) -> Unit)? = null

        /** True if the listener is connected (i.e. permission granted + service bound). */
        var isConnected: Boolean = false
            private set

        /**
         * Snapshot of the current cache, newest first.
         * Returns an empty list if the listener is not connected.
         */
        fun snapshot(): List<CachedNotification> {
            val ref = instance ?: return emptyList()
            return synchronized(ref.cache) { ref.cache.toList() }
        }

        /** Find a cached notification by its id (uniqueId() of an SBN). */
        fun findById(id: String): CachedNotification? {
            val ref = instance ?: return null
            return synchronized(ref.cache) { ref.cache.firstOrNull { it.id == id } }
        }

        /**
         * Reply to a notification by its cached ID.
         * Returns a result map: { success: Boolean, error: String? }
         */
        fun replyToNotification(notifId: String, message: String): Map<String, Any?> {
            val ref = instance
                ?: return mapOf("success" to false, "error" to "listener_not_connected")

            // Find the live StatusBarNotification from the system.
            val sbn = try {
                ref.activeNotifications?.firstOrNull { ref.uniqueId(it) == notifId }
            } catch (e: Exception) {
                Log.w(TAG, "Failed to access active notifications: ${e.message}")
                null
            } ?: return mapOf("success" to false, "error" to "notification_not_found")

            // Find a reply action with RemoteInput.
            val (action, remoteInput) = findReplyAction(sbn)
                ?: return mapOf("success" to false, "error" to "no_reply_action")

            // Build the reply intent.
            return try {
                val intent = Intent()
                val bundle = Bundle()
                bundle.putCharSequence(remoteInput.resultKey, message)
                android.app.RemoteInput.addResultsToIntent(
                    arrayOf(remoteInput),
                    intent,
                    bundle
                )
                action.actionIntent.send(ref, 0, intent)
                Log.d(TAG, "Reply sent to $notifId: ${message.take(30)}...")
                mapOf("success" to true, "error" to null)
            } catch (e: PendingIntent.CanceledException) {
                Log.w(TAG, "Reply PendingIntent was cancelled: ${e.message}")
                mapOf("success" to false, "error" to "intent_cancelled")
            } catch (e: Exception) {
                Log.w(TAG, "Reply failed: ${e.message}")
                mapOf("success" to false, "error" to e.message)
            }
        }

        /**
         * Check if a notification has a reply action.
         */
        fun hasReplyAction(notifId: String): Boolean {
            val ref = instance ?: return false
            val sbn = try {
                ref.activeNotifications?.firstOrNull { ref.uniqueId(it) == notifId }
            } catch (_: Exception) {
                null
            } ?: return false
            return findReplyAction(sbn) != null
        }

        /**
         * Find the reply action and its RemoteInput from a StatusBarNotification.
         */
        private fun findReplyAction(sbn: StatusBarNotification): Pair<Notification.Action, android.app.RemoteInput>? {
            val actions = sbn.notification.actions ?: return null
            for (action in actions) {
                val inputs = action.remoteInputs ?: continue
                for (input in inputs) {
                    // RemoteInput with allowFreeFormInput = true is a reply field.
                    if (input.allowFreeFormInput) {
                        return Pair(action, input)
                    }
                }
            }
            return null
        }
    }

    /** Cache ordered newest-first. */
    private val cache: ArrayDeque<CachedNotification> = ArrayDeque()

    override fun onListenerConnected() {
        super.onListenerConnected()
        instance = this
        isConnected = true
        Log.d(TAG, "Listener connected")
        try {
            // Seed cache with whatever is currently in the shade.
            activeNotifications?.forEach { sbn ->
                addOrUpdate(sbn, notify = false)
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to seed cache: ${e.message}")
        }
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        Log.d(TAG, "Listener disconnected")
        isConnected = false
        instance = null
        synchronized(cache) { cache.clear() }
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        sbn ?: return
        try {
            addOrUpdate(sbn, notify = true)
        } catch (e: Exception) {
            Log.w(TAG, "onNotificationPosted error: ${e.message}")
        }
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        sbn ?: return
        try {
            val id = uniqueId(sbn)
            synchronized(cache) {
                cache.removeAll { it.id == id }
            }
        } catch (e: Exception) {
            Log.w(TAG, "onNotificationRemoved error: ${e.message}")
        }
    }

    private fun addOrUpdate(sbn: StatusBarNotification, notify: Boolean = true) {
        val cached = toCached(sbn) ?: return
        // Skip self-posted notifications to prevent recursive triggers.
        if (cached.packageName == this.packageName) return
        synchronized(cache) {
            // Remove existing entry with the same id (notifications can be updated in place).
            cache.removeAll { it.id == cached.id }
            cache.addFirst(cached)
            while (cache.size > MAX_CACHE) cache.removeLast()
        }
        if (notify) {
            try {
                onPostedCallback?.invoke(cached)
            } catch (e: Exception) {
                Log.w(TAG, "onPostedCallback error: ${e.message}")
            }
        }
    }

    private fun toCached(sbn: StatusBarNotification): CachedNotification? {
        val extras = sbn.notification.extras ?: return null

        val title = extras.getCharSequence("android.title")?.toString()
        val text = extras.getCharSequence("android.text")?.toString()
            ?: extras.getCharSequence("android.bigText")?.toString()

        // Skip empty/system-only notifications (e.g. media style with no text).
        if (title.isNullOrBlank() && text.isNullOrBlank()) return null

        val appName = resolveAppName(sbn.packageName)
        val hasReply = findReplyAction(sbn) != null

        return CachedNotification(
            id = uniqueId(sbn),
            packageName = sbn.packageName,
            appName = appName,
            title = title,
            text = text,
            timestamp = sbn.postTime,
            clearable = sbn.isClearable,
            hasReplyAction = hasReply
        )
    }

    private fun resolveAppName(packageName: String): String {
        return try {
            val pm = packageManager
            val info = pm.getApplicationInfo(packageName, 0)
            pm.getApplicationLabel(info).toString()
        } catch (_: PackageManager.NameNotFoundException) {
            packageName
        } catch (e: Exception) {
            Log.w(TAG, "resolveAppName error: ${e.message}")
            packageName
        }
    }

    private fun uniqueId(sbn: StatusBarNotification): String {
        // SBN.key is stable per-notification on Android 5+.
        return sbn.key ?: "${sbn.packageName}#${sbn.id}#${sbn.postTime}"
    }
}

data class CachedNotification(
    val id: String,
    val packageName: String,
    val appName: String,
    val title: String?,
    val text: String?,
    val timestamp: Long,
    val clearable: Boolean,
    val hasReplyAction: Boolean = false
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "id" to id,
        "packageName" to packageName,
        "appName" to appName,
        "title" to title,
        "text" to text,
        "timestamp" to timestamp,
        "clearable" to clearable,
        "hasReplyAction" to hasReplyAction
    )
}

