package com.meowagent.meow_agent

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.content.Context
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityManager
import android.view.accessibility.AccessibilityNodeInfo
import java.util.concurrent.ConcurrentLinkedQueue

/**
 * Queued accessibility actions for cross-app automation.
 */
sealed class MeowAccessibilityAction {
    data class SendWhatsApp(val phone: String, val message: String) : MeowAccessibilityAction()
    data class SendWhatsAppGroup(val groupName: String, val message: String) : MeowAccessibilityAction()
    data class WaCall(val phone: String, val video: Boolean) : MeowAccessibilityAction()
}

/**
 * Meow Agent Accessibility Service.
 *
 * Provides cross-app UI automation for:
 * - WhatsApp auto-send (find input → inject text → tap send)
 * - WhatsApp group messaging (find group → open → send)
 * - WhatsApp voice/video calls (open chat → tap call button)
 *
 * Architecture:
 * - Actions are queued from CommunicationPlugin via companion object.
 * - The service processes queued actions when it detects the target app's
 *   window is ready (via onAccessibilityEvent TYPE_WINDOW_STATE_CHANGED).
 * - Retries with delay if UI elements aren't found immediately.
 */
class MeowAccessibilityService : AccessibilityService() {

    companion object {
        private const val TAG = "MeowA11y"
        private const val WA_PACKAGE = "com.whatsapp"
        private const val MAX_RETRIES = 10
        private const val RETRY_DELAY_MS = 500L

        private val actionQueue = ConcurrentLinkedQueue<MeowAccessibilityAction>()
        private var instance: MeowAccessibilityService? = null

        fun queueAction(action: MeowAccessibilityAction) {
            Log.d(TAG, "Queued action: $action")
            actionQueue.add(action)
        }

        fun isEnabled(context: Context): Boolean {
            val am = context.getSystemService(Context.ACCESSIBILITY_SERVICE) as AccessibilityManager
            val services = am.getEnabledAccessibilityServiceList(AccessibilityServiceInfo.FEEDBACK_ALL_MASK)
            val myService = "${context.packageName}/.MeowAccessibilityService"
            return services.any {
                it.resolveInfo.serviceInfo.let { info ->
                    "${info.packageName}/${info.name}" == myService ||
                    info.name == MeowAccessibilityService::class.java.name
                }
            }
        }
    }

    private val handler = Handler(Looper.getMainLooper())
    private var retryCount = 0

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        Log.d(TAG, "Accessibility Service connected")
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    override fun onInterrupt() {
        Log.w(TAG, "Accessibility Service interrupted")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        if (actionQueue.isEmpty()) return

        val packageName = event.packageName?.toString() ?: return

        // Only process events from WhatsApp.
        if (packageName != WA_PACKAGE) return

        // Process on window state change (screen ready).
        if (event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED ||
            event.eventType == AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED) {
            handler.postDelayed({ processQueue() }, 300)
        }
    }

    private fun processQueue() {
        val action = actionQueue.peek() ?: return
        val root = rootInActiveWindow ?: return

        Log.d(TAG, "Processing action: $action (retry: $retryCount)")

        val success = when (action) {
            is MeowAccessibilityAction.SendWhatsApp -> handleSendWhatsApp(root, action)
            is MeowAccessibilityAction.SendWhatsAppGroup -> handleSendWhatsAppGroup(root, action)
            is MeowAccessibilityAction.WaCall -> handleWaCall(root, action)
        }

        if (success) {
            actionQueue.poll()
            retryCount = 0
            Log.d(TAG, "Action completed successfully")
        } else {
            retryCount++
            if (retryCount >= MAX_RETRIES) {
                actionQueue.poll()
                retryCount = 0
                Log.w(TAG, "Action failed after $MAX_RETRIES retries, dropping.")
            } else {
                handler.postDelayed({ processQueue() }, RETRY_DELAY_MS)
            }
        }

        root.recycle()
    }

    // ─── WhatsApp Send Message ───────────────────────────────────────

    private fun handleSendWhatsApp(root: AccessibilityNodeInfo, action: MeowAccessibilityAction.SendWhatsApp): Boolean {
        // Find the message input field.
        val inputField = findNodeByResourceId(root, "$WA_PACKAGE:id/entry")
            ?: findEditText(root)
            ?: return false

        // Set the message text.
        val args = Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, action.message)
        }
        inputField.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)

        // Small delay then find and tap send button.
        handler.postDelayed({
            val freshRoot = rootInActiveWindow ?: return@postDelayed
            val sendButton = findNodeByResourceId(freshRoot, "$WA_PACKAGE:id/send")
                ?: findNodeByContentDescription(freshRoot, "Send")
            sendButton?.performAction(AccessibilityNodeInfo.ACTION_CLICK)
            freshRoot.recycle()
        }, 200)

        return true
    }

    // ─── WhatsApp Group Message ──────────────────────────────────────

    private fun handleSendWhatsAppGroup(root: AccessibilityNodeInfo, action: MeowAccessibilityAction.SendWhatsAppGroup): Boolean {
        // First, check if we're already in a chat (input field visible).
        val inputField = findNodeByResourceId(root, "$WA_PACKAGE:id/entry")
            ?: findEditText(root)

        if (inputField != null) {
            // Already in chat, send the message.
            val args = Bundle().apply {
                putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, action.message)
            }
            inputField.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)

            handler.postDelayed({
                val freshRoot = rootInActiveWindow ?: return@postDelayed
                val sendButton = findNodeByResourceId(freshRoot, "$WA_PACKAGE:id/send")
                    ?: findNodeByContentDescription(freshRoot, "Send")
                sendButton?.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                freshRoot.recycle()
            }, 200)
            return true
        }

        // Not in chat yet — find and click the group in the list.
        val groupNode = findNodeByText(root, action.groupName)
        if (groupNode != null) {
            groupNode.performAction(AccessibilityNodeInfo.ACTION_CLICK)
            // Will retry on next event when chat opens.
            return false
        }

        return false
    }

    // ─── WhatsApp Call ────────────────────────────────────────────────

    private fun handleWaCall(root: AccessibilityNodeInfo, action: MeowAccessibilityAction.WaCall): Boolean {
        // Look for voice/video call button in the chat header.
        val desc = if (action.video) "Video call" else "Voice call"
        val callButton = findNodeByContentDescription(root, desc)
            ?: findNodeByContentDescription(root, if (action.video) "Panggilan video" else "Panggilan suara")

        if (callButton != null) {
            callButton.performAction(AccessibilityNodeInfo.ACTION_CLICK)
            return true
        }

        // Try the overflow menu approach: find call icons by resource ID.
        val voiceBtn = findNodeByResourceId(root, "$WA_PACKAGE:id/menuitem_audio_call")
            ?: findNodeByResourceId(root, "$WA_PACKAGE:id/call_btn")
        val videoBtn = findNodeByResourceId(root, "$WA_PACKAGE:id/menuitem_video_call")
            ?: findNodeByResourceId(root, "$WA_PACKAGE:id/video_btn")

        val targetBtn = if (action.video) videoBtn else voiceBtn
        if (targetBtn != null) {
            targetBtn.performAction(AccessibilityNodeInfo.ACTION_CLICK)
            return true
        }

        return false
    }

    // ─── Node Search Helpers ─────────────────────────────────────────

    private fun findNodeByResourceId(root: AccessibilityNodeInfo, resId: String): AccessibilityNodeInfo? {
        val nodes = root.findAccessibilityNodeInfosByViewId(resId)
        return nodes?.firstOrNull()
    }

    private fun findNodeByContentDescription(root: AccessibilityNodeInfo, desc: String): AccessibilityNodeInfo? {
        return traverseAndFind(root) { node ->
            node.contentDescription?.toString()?.contains(desc, ignoreCase = true) == true
        }
    }

    private fun findNodeByText(root: AccessibilityNodeInfo, text: String): AccessibilityNodeInfo? {
        val nodes = root.findAccessibilityNodeInfosByText(text)
        return nodes?.firstOrNull { it.isClickable }
            ?: nodes?.firstOrNull()?.parent
    }

    private fun findEditText(root: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        return traverseAndFind(root) { node ->
            node.className?.toString() == "android.widget.EditText" && node.isEditable
        }
    }

    private fun traverseAndFind(
        node: AccessibilityNodeInfo,
        predicate: (AccessibilityNodeInfo) -> Boolean
    ): AccessibilityNodeInfo? {
        if (predicate(node)) return node
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            val found = traverseAndFind(child, predicate)
            if (found != null) return found
        }
        return null
    }
}
