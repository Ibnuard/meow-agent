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
 * - WhatsApp group messaging (search → open group → send)
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
        private const val MAX_RETRIES = 15
        private const val RETRY_DELAY_MS = 600L

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

    // Track group send state machine.
    private var groupState: GroupSendState = GroupSendState.IDLE

    private enum class GroupSendState {
        IDLE,
        SEARCHING,        // Waiting for search field to appear
        TYPING_SEARCH,    // Typed group name in search, waiting for results
        OPENING_CHAT,     // Clicked search result, waiting for chat to open
        SENDING           // Chat open, ready to send message
    }

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
            handler.postDelayed({ processQueue() }, 400)
        }
    }

    private fun processQueue() {
        val action = actionQueue.peek() ?: return
        val root = rootInActiveWindow ?: return

        Log.d(TAG, "Processing action: $action (retry: $retryCount, groupState: $groupState)")

        val success = when (action) {
            is MeowAccessibilityAction.SendWhatsApp -> handleSendWhatsApp(root, action)
            is MeowAccessibilityAction.SendWhatsAppGroup -> handleSendWhatsAppGroup(root, action)
            is MeowAccessibilityAction.WaCall -> handleWaCall(root, action)
        }

        if (success) {
            actionQueue.poll()
            retryCount = 0
            groupState = GroupSendState.IDLE
            Log.d(TAG, "Action completed successfully")
        } else {
            retryCount++
            if (retryCount >= MAX_RETRIES) {
                actionQueue.poll()
                retryCount = 0
                groupState = GroupSendState.IDLE
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
                ?: findNodeByContentDescription(freshRoot, "Kirim")
            sendButton?.performAction(AccessibilityNodeInfo.ACTION_CLICK)
            freshRoot.recycle()
        }, 300)

        return true
    }

    // ─── WhatsApp Group Message ──────────────────────────────────────

    private fun handleSendWhatsAppGroup(root: AccessibilityNodeInfo, action: MeowAccessibilityAction.SendWhatsAppGroup): Boolean {
        when (groupState) {
            GroupSendState.IDLE -> {
                // Step 1: Try to find the group directly in the visible chat list.
                // This is the most reliable approach for modern WA versions.
                val chatItem = findGroupInChatList(root, action.groupName)

                if (chatItem != null) {
                    chatItem.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                    groupState = GroupSendState.OPENING_CHAT
                    Log.d(TAG, "Clicked group '${action.groupName}' directly from chat list")
                    return false // Wait for chat to open
                }

                // Group not visible in list — try the search bar approach.
                // Modern WA uses a search bar (my_search_bar) instead of a search icon.
                val searchBar = findNodeByResourceId(root, "$WA_PACKAGE:id/search_bar_inner_layout")
                    ?: findNodeByResourceId(root, "$WA_PACKAGE:id/menuitem_search")
                    ?: findNodeByContentDescription(root, "Search")
                    ?: findNodeByContentDescription(root, "Cari")

                if (searchBar != null) {
                    searchBar.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                    groupState = GroupSendState.SEARCHING
                    Log.d(TAG, "Group not in visible list, clicked search bar")
                    return false
                }

                // Debug dump on retry 3 to help diagnose.
                if (retryCount == 3) {
                    logNodeTree(root, 0)
                }

                Log.d(TAG, "Neither group nor search found, retrying...")
                return false
            }

            GroupSendState.SEARCHING -> {
                // Step 2: Find the search input field and type group name.
                val searchField = findNodeByResourceId(root, "$WA_PACKAGE:id/search_src_text")
                    ?: findNodeByResourceId(root, "$WA_PACKAGE:id/search_input")
                    ?: findNodeByResourceId(root, "$WA_PACKAGE:id/search_edit_text")
                    ?: findNodeByResourceId(root, "$WA_PACKAGE:id/edittext_search")
                    ?: findFocusedEditText(root)
                    ?: findAnyEditableNode(root)

                if (searchField != null) {
                    val args = Bundle().apply {
                        putCharSequence(
                            AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                            action.groupName
                        )
                    }
                    searchField.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
                    groupState = GroupSendState.TYPING_SEARCH
                    Log.d(TAG, "Typed group name in search: ${action.groupName}")
                    return false
                }

                // If search screen didn't open, maybe group appeared in list now.
                val chatItem = findGroupInChatList(root, action.groupName)
                if (chatItem != null) {
                    chatItem.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                    groupState = GroupSendState.OPENING_CHAT
                    Log.d(TAG, "Found group in list while waiting for search")
                    return false
                }

                Log.d(TAG, "Search field not found yet, retrying...")
                return false
            }

            GroupSendState.TYPING_SEARCH -> {
                // Step 3: Find and click the first search result.
                val resultNode = findGroupInChatList(root, action.groupName)
                    ?: findFirstSearchResult(root)

                if (resultNode != null) {
                    resultNode.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                    groupState = GroupSendState.OPENING_CHAT
                    Log.d(TAG, "Clicked search result")
                    return false
                }

                Log.d(TAG, "Search results not found yet, retrying...")
                return false
            }

            GroupSendState.OPENING_CHAT, GroupSendState.SENDING -> {
                // Step 4: Chat is open, find input and send message.
                val inputField = findNodeByResourceId(root, "$WA_PACKAGE:id/entry")
                    ?: findEditText(root)

                if (inputField != null) {
                    val args = Bundle().apply {
                        putCharSequence(
                            AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                            action.message
                        )
                    }
                    inputField.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)

                    handler.postDelayed({
                        val freshRoot = rootInActiveWindow ?: return@postDelayed
                        val sendButton = findNodeByResourceId(freshRoot, "$WA_PACKAGE:id/send")
                            ?: findNodeByContentDescription(freshRoot, "Send")
                            ?: findNodeByContentDescription(freshRoot, "Kirim")
                        sendButton?.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                        freshRoot.recycle()
                        Log.d(TAG, "Message sent to group!")
                    }, 300)

                    return true
                }

                groupState = GroupSendState.SENDING
                Log.d(TAG, "Chat input not found yet, waiting for chat to open...")
                return false
            }
        }
    }

    /**
     * Find a group/contact in the visible WA chat list by fuzzy-matching
     * the name against conversations_row_contact_name TextViews.
     *
     * Returns the clickable parent (contact_row_container) if found.
     * Matching logic: case-insensitive contains in either direction,
     * so "The Most Secreti" matches "The Most Secrets" (partial overlap).
     */
    private fun findGroupInChatList(root: AccessibilityNodeInfo, targetName: String): AccessibilityNodeInfo? {
        val nameNodes = root.findAccessibilityNodeInfosByViewId(
            "$WA_PACKAGE:id/conversations_row_contact_name"
        ) ?: return null

        val target = targetName.lowercase().trim()

        // First pass: exact match (case-insensitive).
        for (node in nameNodes) {
            val nodeName = node.text?.toString()?.lowercase()?.trim() ?: continue
            if (nodeName == target) {
                return findClickableParent(node)
            }
        }

        // Second pass: one contains the other (handles typos where one is a prefix).
        for (node in nameNodes) {
            val nodeName = node.text?.toString()?.lowercase()?.trim() ?: continue
            if (nodeName.contains(target) || target.contains(nodeName)) {
                return findClickableParent(node)
            }
        }

        // Third pass: significant overlap (Jaccard-like on words).
        for (node in nameNodes) {
            val nodeName = node.text?.toString()?.lowercase()?.trim() ?: continue
            if (fuzzyMatch(target, nodeName)) {
                return findClickableParent(node)
            }
        }

        return null
    }

    /**
     * Walk up the tree to find the nearest clickable parent
     * (typically contact_row_container).
     */
    private fun findClickableParent(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        var current: AccessibilityNodeInfo? = node
        while (current != null) {
            if (current.isClickable) return current
            current = current.parent
        }
        return null
    }

    /**
     * Simple fuzzy match: checks if most words from the query appear
     * in the candidate (handles 1-char typos at word boundaries).
     */
    private fun fuzzyMatch(query: String, candidate: String): Boolean {
        val queryWords = query.split(" ").filter { it.isNotEmpty() }
        val candidateWords = candidate.split(" ").filter { it.isNotEmpty() }
        if (queryWords.isEmpty() || candidateWords.isEmpty()) return false

        // Count how many query words have a close match in candidate.
        var matches = 0
        for (qw in queryWords) {
            for (cw in candidateWords) {
                if (cw.startsWith(qw.take(qw.length - 1)) ||
                    qw.startsWith(cw.take(cw.length - 1)) ||
                    cw.contains(qw) || qw.contains(cw)) {
                    matches++
                    break
                }
            }
        }
        // At least 60% of words should match.
        return matches >= (queryWords.size * 0.6)
    }

    /**
     * Find the first clickable search result item below the search bar.
     * WhatsApp shows results in a RecyclerView — we look for the first
     * clickable ViewGroup that contains text.
     */
    private fun findFirstSearchResult(root: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        // Look for the conversations list / search results recycler.
        val recycler = findNodeByResourceId(root, "$WA_PACKAGE:id/recycler_view_messages")
            ?: findNodeByResourceId(root, "$WA_PACKAGE:id/contact_list")
            ?: findNodeByResourceId(root, "$WA_PACKAGE:id/search_results_list")

        if (recycler != null && recycler.childCount > 0) {
            // Return the first clickable child.
            for (i in 0 until recycler.childCount) {
                val child = recycler.getChild(i) ?: continue
                if (child.isClickable) return child
                // If child isn't clickable, check its parent.
                val parent = child.parent
                if (parent != null && parent.isClickable) return parent
            }
        }

        // Fallback: find any clickable node that looks like a chat item.
        return traverseAndFind(root) { node ->
            node.isClickable &&
            node.className?.toString() in listOf(
                "android.widget.RelativeLayout",
                "android.widget.FrameLayout",
                "android.view.ViewGroup"
            ) &&
            hasChildWithText(node)
        }
    }

    private fun hasChildWithText(node: AccessibilityNodeInfo): Boolean {
        if (!node.text.isNullOrEmpty()) return true
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            if (!child.text.isNullOrEmpty()) return true
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
            ?: nodes?.firstOrNull()?.let { node ->
                // Walk up to find the nearest clickable parent.
                var current: AccessibilityNodeInfo? = node
                while (current != null) {
                    if (current.isClickable) return current
                    current = current.parent
                }
                null
            }
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

    /**
     * Find an EditText that currently has focus — after clicking search,
     * the search field is usually auto-focused.
     */
    private fun findFocusedEditText(root: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        return traverseAndFind(root) { node ->
            node.isFocused && (
                node.className?.toString() == "android.widget.EditText" ||
                node.className?.toString() == "android.widget.AutoCompleteTextView" ||
                node.isEditable
            )
        }
    }

    /**
     * Find ANY editable node on screen — broadest possible fallback.
     * Skips the main chat input by checking if it's within a search-related parent.
     */
    private fun findAnyEditableNode(root: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        return traverseAndFind(root) { node ->
            node.isEditable && node.className?.toString()?.let { cls ->
                cls.contains("EditText") || cls.contains("AutoCompleteTextView")
            } == true
        }
    }

    /**
     * Debug: log the accessibility node tree to help identify correct resource IDs.
     */
    private fun logNodeTree(node: AccessibilityNodeInfo, depth: Int) {
        val indent = "  ".repeat(depth)
        val resId = node.viewIdResourceName ?: "no-id"
        val cls = node.className?.toString() ?: "?"
        val text = node.text?.toString()?.take(30) ?: ""
        val desc = node.contentDescription?.toString()?.take(30) ?: ""
        val flags = buildString {
            if (node.isEditable) append("E")
            if (node.isFocused) append("F")
            if (node.isClickable) append("C")
        }
        Log.d(TAG, "$indent[$cls] id=$resId text=\"$text\" desc=\"$desc\" flags=$flags")
        for (i in 0 until node.childCount.coerceAtMost(20)) {
            val child = node.getChild(i) ?: continue
            logNodeTree(child, depth + 1)
        }
    }
}
