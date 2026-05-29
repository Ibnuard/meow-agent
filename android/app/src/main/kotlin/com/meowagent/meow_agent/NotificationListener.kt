package com.meowagent.meow_agent

import android.content.pm.PackageManager
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log

/**
 * Read-only notification listener.
 *
 * Maintains an in-memory cache (max 100) of the most recent notifications
 * posted on the device. The cache is exposed to Flutter via the channel
 * handler in [MainActivity] — this service NEVER dismisses, replies to, or
 * otherwise mutates notification state.
 *
 * Cache survives across activity restarts as long as the system keeps the
 * service alive. We do NOT persist to disk in MVP.
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

        return CachedNotification(
            id = uniqueId(sbn),
            packageName = sbn.packageName,
            appName = appName,
            title = title,
            text = text,
            timestamp = sbn.postTime,
            clearable = sbn.isClearable
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
    val clearable: Boolean
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "id" to id,
        "packageName" to packageName,
        "appName" to appName,
        "title" to title,
        "text" to text,
        "timestamp" to timestamp,
        "clearable" to clearable
    )
}
