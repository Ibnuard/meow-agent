package com.meowagent.meow_agent

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.content.Context
import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.util.SparseArray
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityManager
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
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

        // Shared traversal limits used by serializeNode (inspect),
        // findSerializedNodeById (click/set_text/scroll target lookup),
        // and findByTextRecurse (find_by_text). These MUST match across all
        // three traversals so an id returned by one resolves to the same node
        // in the others.
        const val TREE_MAX_DEPTH = 25
        const val TREE_MAX_NODES = 400

        private val actionQueue = ConcurrentLinkedQueue<MeowAccessibilityAction>()
        private var instance: MeowAccessibilityService? = null

        @Volatile
        private var foregroundPackage: String? = null

        /** Last package name observed in a TYPE_WINDOW_STATE_CHANGED event. */
        fun currentForegroundPackage(): String? = foregroundPackage

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

        /**
         * Capture accessibility tree from a specific display.
         * Returns null if service not connected or API < 33.
         */
        fun captureTreeFromDisplay(displayId: Int): Map<String, Any?>? {
            return instance?.captureTreeFromDisplayInternal(displayId)
        }

        /**
         * Capture accessibility tree from the default (primary) display.
         */
        fun captureDefaultTree(): Map<String, Any?>? {
            return instance?.captureDefaultTreeInternal()
        }

        /**
         * Get all available display IDs that have accessibility windows.
         */
        fun getAvailableDisplays(): List<Int> {
            return instance?.getAvailableDisplaysInternal() ?: emptyList()
        }

        fun performNodeAction(
            nodeId: Int,
            action: String,
            text: String?,
            direction: String?
        ): Map<String, Any?> {
            return instance?.performNodeActionInternal(nodeId, action, text, direction)
                ?: mapOf(
                    "success" to false,
                    "error" to "accessibility_service_not_connected"
                )
        }

        fun performGlobalBack(): Map<String, Any?> {
            val svc = instance ?: return mapOf(
                "success" to false,
                "error" to "accessibility_service_not_connected"
            )
            val ok = svc.performGlobalAction(GLOBAL_ACTION_BACK)
            return mapOf("success" to ok, "action" to "global_back")
        }

        fun findByText(query: String, mode: String): Map<String, Any?> {
            val svc = instance ?: return mapOf(
                "success" to false,
                "error" to "accessibility_service_not_connected"
            )
            return svc.findByTextInternal(query, mode)
        }

        fun clickByText(query: String, mode: String): Map<String, Any?> {
            val svc = instance ?: return mapOf(
                "success" to false,
                "error" to "accessibility_service_not_connected"
            )
            return svc.clickByTextInternal(query, mode)
        }

        /**
         * Perform IME Enter action on the currently focused EditText.
         * Works without Shizuku — uses accessibility ACTION_IME_ENTER (API 30+)
         * or falls back to ACTION_NEXT / ACTION_SET_TEXT with newline.
         */
        fun performImeEnter(): Map<String, Any?> {
            val svc = instance ?: return mapOf(
                "success" to false,
                "error" to "accessibility_service_not_connected"
            )
            return svc.performImeEnterInternal()
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

        // Track the foreground package using the windows API rather than the
        // event's raw packageName. Raw packageName can be misleading: our own
        // overlay windows fire TYPE_WINDOW_STATE_CHANGED events with our
        // package, and stale state can persist if we filter those naively.
        // The windows API gives us the authoritative top APPLICATION window.
        if (event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED ||
            event.eventType == AccessibilityEvent.TYPE_WINDOWS_CHANGED) {
            val topPkg = resolveTopApplicationPackage()
            if (!topPkg.isNullOrEmpty() && topPkg != foregroundPackage) {
                foregroundPackage = topPkg
                AppAgentOverlayService.notifyForegroundChanged(applicationContext, topPkg)
            }
        }

        if (actionQueue.isEmpty()) return

        val packageName = event.packageName?.toString() ?: return

        // Only process queued actions when the target (WhatsApp) is in front.
        if (packageName != WA_PACKAGE) return

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

    // ─── Virtual Display Tree Capture ────────────────────────────────────

    /**
     * Capture accessibility tree from a specific display using API 33+.
     * Returns a map with display info, window count, and serialized node tree.
     */
    internal fun captureTreeFromDisplayInternal(displayId: Int): Map<String, Any?>? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            Log.w(TAG, "getWindowsOnAllDisplays requires API 33+, current: ${Build.VERSION.SDK_INT}")
            return mapOf(
                "error" to "API 33+ required",
                "current_api" to Build.VERSION.SDK_INT
            )
        }

        try {
            val windowsMap = getWindowsOnAllDisplays()
            val displayWindows = windowsMap[displayId]

            if (displayWindows == null || displayWindows.isEmpty()) {
                val availableKeys = (0 until windowsMap.size()).map { windowsMap.keyAt(it) }
                Log.w(TAG, "No windows found on display $displayId. Available displays: $availableKeys")
                val windowCounts = mutableMapOf<Int, Int>()
                for (i in 0 until windowsMap.size()) {
                    windowCounts[windowsMap.keyAt(i)] = windowsMap.valueAt(i).size
                }
                return mapOf(
                    "error" to "no_windows_on_display",
                    "target_display" to displayId,
                    "available_displays" to availableKeys,
                    "all_window_counts" to windowCounts
                )
            }

            val result = mutableMapOf<String, Any?>()
            result["display_id"] = displayId
            result["window_count"] = displayWindows.size
            result["success"] = true

            val windowsList = mutableListOf<Map<String, Any?>>()
            var totalNodes = 0

            for (window in displayWindows) {
                val root = window.root
                val windowInfo = mutableMapOf<String, Any?>(
                    "window_id" to window.id,
                    "window_type" to windowTypeToString(window.type),
                    "window_layer" to window.layer,
                    "has_root" to (root != null)
                )

                if (root != null) {
                    val nodes = mutableListOf<Map<String, Any?>>()
                    val counter = intArrayOf(0)
                    serializeNode(root, nodes, 0, TREE_MAX_DEPTH, counter, TREE_MAX_NODES)
                    windowInfo["package"] = root.packageName?.toString()
                    windowInfo["nodes"] = nodes
                    windowInfo["node_count"] = nodes.size
                    totalNodes += nodes.size
                    root.recycle()
                }

                windowsList.add(windowInfo)
            }

            result["windows"] = windowsList
            result["total_nodes"] = totalNodes
            Log.d(TAG, "Captured tree from display $displayId: ${displayWindows.size} windows, $totalNodes nodes")
            return result

        } catch (e: Exception) {
            Log.e(TAG, "Error capturing tree from display $displayId", e)
            return mapOf(
                "error" to "exception",
                "message" to (e.message ?: "unknown"),
                "display_id" to displayId
            )
        }
    }

    /**
     * Capture accessibility tree from the primary display (default rootInActiveWindow).
     */
    internal fun captureDefaultTreeInternal(): Map<String, Any?>? {
        val root = rootInActiveWindow
        if (root == null) {
            Log.w(TAG, "captureDefaultTree: rootInActiveWindow is null")
            return mapOf(
                "error" to "no_active_window",
                "message" to "rootInActiveWindow returned null"
            )
        }

        val pkg = root.packageName?.toString() ?: "unknown"
        val childCount = root.childCount
        Log.d(TAG, "captureDefaultTree: package=$pkg, rootChildCount=$childCount, " +
                "className=${root.className}, text=${root.text}, " +
                "clickable=${root.isClickable}, scrollable=${root.isScrollable}")

        try {
            val nodes = mutableListOf<Map<String, Any?>>()
            val counter = intArrayOf(0)
            val visited = intArrayOf(0)
            serializeNode(root, nodes, 0, TREE_MAX_DEPTH, counter, TREE_MAX_NODES, visited)

            Log.d(TAG, "captureDefaultTree: serialized ${nodes.size} interesting nodes " +
                    "out of ${visited[0]} visited (package=$pkg)")

            if (nodes.isEmpty() && childCount > 0) {
                Log.w(TAG, "captureDefaultTree: ROOT HAS CHILDREN ($childCount) BUT " +
                        "ZERO INTERESTING NODES. Dumping first 3 levels...")
                dumpTreeDebug(root, 0, 3)
            }

            val result = mapOf<String, Any?>(
                "success" to true,
                "display_id" to 0,
                "package" to pkg,
                "node_count" to nodes.size,
                "nodes" to nodes
            )
            root.recycle()
            return result
        } catch (e: Exception) {
            Log.e(TAG, "Error capturing default tree", e)
            return mapOf("error" to "exception", "message" to (e.message ?: "unknown"))
        }
    }

    /**
     * Search the accessibility tree for nodes matching [query] in either
     * text or contentDescription. Returns up to 20 matches in the same node
     * shape as inspect, ready to use with click/set_text.
     *
     * Unlike inspect, this walks EVERY node (not just "interesting" ones)
     * because chat names, contact names, and labels often live in deeply
     * nested non-interactive TextViews. When a match is found on such a leaf,
     * we walk up to the nearest clickable ancestor and return THAT node so
     * click() actually opens the item.
     *
     * [mode]: "exact" = whole-string equality (case-insensitive)
     *         "contains" = substring match (default, case-insensitive)
     */
    internal fun findByTextInternal(query: String, mode: String): Map<String, Any?> {
        if (query.isBlank()) {
            return mapOf("success" to false, "error" to "empty_query")
        }
        val root = rootInActiveWindow ?: return mapOf(
            "success" to false,
            "error" to "no_active_window"
        )
        val pkg = root.packageName?.toString() ?: "unknown"
        val needle = query.trim().lowercase()
        val exact = mode.equals("exact", ignoreCase = true)
        val matches = mutableListOf<Map<String, Any?>>()
        // Track which interactable ancestors we've already reported so we
        // don't return duplicates when several leaves under the same item match.
        val reportedAncestors = HashSet<Int>()
        val counter = intArrayOf(0)
        val visited = intArrayOf(0)

        try {
            findByTextRecurse(
                node = root,
                needle = needle,
                exact = exact,
                matches = matches,
                reportedAncestors = reportedAncestors,
                counter = counter,
                visited = visited,
                depth = 0,
                maxDepth = TREE_MAX_DEPTH,
                maxScan = TREE_MAX_NODES,
                maxMatches = 20
            )
            Log.d(TAG, "findByText('$query', $mode): ${matches.size} matches " +
                    "from ${visited[0]} visited nodes (package=$pkg)")
            val result = mapOf<String, Any?>(
                "success" to true,
                "package" to pkg,
                "query" to query,
                "mode" to (if (exact) "exact" else "contains"),
                "match_count" to matches.size,
                "scanned" to visited[0],
                "nodes" to matches
            )
            root.recycle()
            return result
        } catch (e: Exception) {
            Log.e(TAG, "findByText failed", e)
            return mapOf("success" to false, "error" to "exception", "message" to (e.message ?: "unknown"))
        }
    }

    private fun findByTextRecurse(
        node: AccessibilityNodeInfo,
        needle: String,
        exact: Boolean,
        matches: MutableList<Map<String, Any?>>,
        reportedAncestors: HashSet<Int>,
        counter: IntArray,
        visited: IntArray,
        depth: Int,
        maxDepth: Int,
        maxScan: Int,
        maxMatches: Int
    ) {
        if (depth > maxDepth || visited[0] >= maxScan || matches.size >= maxMatches) return
        visited[0]++

        // Only "interesting" nodes get IDs (matches inspect's numbering so
        // the agent can also call inspect and use the same ID space).
        val text = node.text?.toString()
        val desc = node.contentDescription?.toString()
        val isInteresting = !text.isNullOrEmpty() || !desc.isNullOrEmpty() ||
                node.isClickable || node.isEditable || node.isScrollable
        var assignedId = -1
        if (isInteresting) {
            assignedId = counter[0]
            counter[0]++
        }

        // Match against EVERY node, not just "interesting" ones — many list
        // items have their label in a leaf TextView whose own flags don't pass
        // the inspect filter.
        val textLc = text?.lowercase() ?: ""
        val descLc = desc?.lowercase() ?: ""
        val matched = if (exact) {
            (textLc.isNotEmpty() && textLc == needle) ||
                    (descLc.isNotEmpty() && descLc == needle)
        } else {
            (textLc.isNotEmpty() && textLc.contains(needle)) ||
                    (descLc.isNotEmpty() && descLc.contains(needle))
        }

        if (matched) {
            // Walk up to find the nearest clickable / focusable ancestor so
            // a downstream click() actually opens the item rather than the
            // inert label inside it.
            val target = resolveClickableAncestor(node) ?: node
            val targetHash = System.identityHashCode(target)
            if (!reportedAncestors.contains(targetHash)) {
                reportedAncestors.add(targetHash)
                val bounds = Rect()
                target.getBoundsInScreen(bounds)
                val width = bounds.right - bounds.left
                val height = bounds.bottom - bounds.top
                val screenW = resources.displayMetrics.widthPixels
                val screenH = resources.displayMetrics.heightPixels
                val onScreen = width > 0 && height > 0 &&
                        bounds.right > 0 && bounds.bottom > 0 &&
                        bounds.left < screenW && bounds.top < screenH

                if (onScreen) {
                    // The reported id should match how the agent will see it
                    // when it later calls inspect — use assignedId if this
                    // node itself is interesting, else -1 (caller can use
                    // the bounds to act, but the agent should re-inspect for
                    // a stable id).
                    matches.add(mapOf(
                        "id" to assignedId,
                        "class" to (target.className?.toString() ?: ""),
                        "package" to (target.packageName?.toString() ?: ""),
                        "text" to (target.text?.toString() ?: text ?: ""),
                        "desc" to (target.contentDescription?.toString() ?: desc ?: ""),
                        "matched_text" to (text ?: ""),
                        "matched_desc" to (desc ?: ""),
                        "resource_id" to (target.viewIdResourceName ?: ""),
                        "bounds" to listOf(bounds.left, bounds.top, bounds.right, bounds.bottom),
                        "clickable" to target.isClickable,
                        "editable" to target.isEditable,
                        "scrollable" to target.isScrollable,
                        "focused" to target.isFocused,
                        "depth" to depth
                    ))
                }
            }
        }

        for (i in 0 until node.childCount) {
            if (visited[0] >= maxScan || matches.size >= maxMatches) break
            val child = node.getChild(i) ?: continue
            findByTextRecurse(
                node = child,
                needle = needle,
                exact = exact,
                matches = matches,
                reportedAncestors = reportedAncestors,
                counter = counter,
                visited = visited,
                depth = depth + 1,
                maxDepth = maxDepth,
                maxScan = maxScan,
                maxMatches = maxMatches
            )
        }
    }

    internal fun clickByTextInternal(query: String, mode: String): Map<String, Any?> {
        if (query.isBlank()) {
            return mapOf("success" to false, "error" to "empty_query")
        }
        val root = rootInActiveWindow ?: return mapOf(
            "success" to false,
            "error" to "no_active_window"
        )
        val needle = query.trim().lowercase()
        val exact = mode.equals("exact", ignoreCase = true)
        val visited = intArrayOf(0)

        return try {
            val matched = findTextTargetRecurse(
                node = root,
                needle = needle,
                exact = exact,
                visited = visited,
                depth = 0,
                maxDepth = TREE_MAX_DEPTH,
                maxScan = TREE_MAX_NODES
            )
            if (matched == null) {
                mapOf(
                    "success" to false,
                    "error" to "text_not_found",
                    "query" to query,
                    "mode" to (if (exact) "exact" else "contains"),
                    "scanned" to visited[0]
                )
            } else {
                val target = resolveClickableAncestor(matched) ?: matched
                val bounds = Rect()
                target.getBoundsInScreen(bounds)
                val performed = target.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                mapOf(
                    "success" to performed,
                    "action" to "click_by_text",
                    "query" to query,
                    "mode" to (if (exact) "exact" else "contains"),
                    "scanned" to visited[0],
                    "matched_text" to (matched.text?.toString() ?: ""),
                    "matched_desc" to (matched.contentDescription?.toString() ?: ""),
                    "class" to (target.className?.toString() ?: ""),
                    "package" to (target.packageName?.toString() ?: ""),
                    "resource_id" to (target.viewIdResourceName ?: ""),
                    "bounds" to listOf(bounds.left, bounds.top, bounds.right, bounds.bottom),
                    "clickable" to target.isClickable
                )
            }
        } catch (e: Exception) {
            Log.e(TAG, "clickByText failed", e)
            mapOf(
                "success" to false,
                "error" to "exception",
                "message" to (e.message ?: "unknown"),
                "query" to query
            )
        } finally {
            root.recycle()
        }
    }

    private fun findTextTargetRecurse(
        node: AccessibilityNodeInfo,
        needle: String,
        exact: Boolean,
        visited: IntArray,
        depth: Int,
        maxDepth: Int,
        maxScan: Int
    ): AccessibilityNodeInfo? {
        if (depth > maxDepth || visited[0] >= maxScan) return null
        visited[0]++

        val textLc = node.text?.toString()?.lowercase() ?: ""
        val descLc = node.contentDescription?.toString()?.lowercase() ?: ""
        val matched = if (exact) {
            (textLc.isNotEmpty() && textLc == needle) ||
                    (descLc.isNotEmpty() && descLc == needle)
        } else {
            (textLc.isNotEmpty() && textLc.contains(needle)) ||
                    (descLc.isNotEmpty() && descLc.contains(needle))
        }
        if (matched && isVisibleOnScreen(node)) return node

        for (i in 0 until node.childCount) {
            if (visited[0] >= maxScan) break
            val child = node.getChild(i) ?: continue
            val found = findTextTargetRecurse(
                child,
                needle,
                exact,
                visited,
                depth + 1,
                maxDepth,
                maxScan
            )
            if (found != null) return found
        }
        return null
    }

    private fun isVisibleOnScreen(node: AccessibilityNodeInfo): Boolean {
        val bounds = Rect()
        node.getBoundsInScreen(bounds)
        val width = bounds.right - bounds.left
        val height = bounds.bottom - bounds.top
        val screenW = resources.displayMetrics.widthPixels
        val screenH = resources.displayMetrics.heightPixels
        return width > 0 && height > 0 &&
                bounds.right > 0 && bounds.bottom > 0 &&
                bounds.left < screenW && bounds.top < screenH
    }

    /**
     * Walk up the accessibility tree to find the nearest ancestor (or self)
     * that is clickable or long-clickable. Returns null if none found within
     * 6 hops (chat list items are usually within 3-4 levels of the label).
     */
    private fun resolveClickableAncestor(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        var current: AccessibilityNodeInfo? = node
        var hops = 0
        while (current != null && hops < 6) {
            if (current.isClickable || current.isLongClickable) return current
            current = current.parent
            hops++
        }
        return null
    }

    /** Debug helper: dump raw tree structure to logcat without any pruning. */
    private fun dumpTreeDebug(node: AccessibilityNodeInfo, depth: Int, maxDepth: Int) {
        if (depth > maxDepth) return
        val indent = "  ".repeat(depth)
        val text = node.text?.toString()?.take(30)
        val desc = node.contentDescription?.toString()?.take(30)
        val cls = node.className?.toString()?.substringAfterLast('.') ?: "?"
        val pkg = node.packageName?.toString() ?: "?"
        Log.d(TAG, "${indent}[$depth] $cls pkg=$pkg text=$text desc=$desc " +
                "click=${node.isClickable} edit=${node.isEditable} " +
                "scroll=${node.isScrollable} children=${node.childCount}")
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            dumpTreeDebug(child, depth + 1, maxDepth)
        }
    }
    /**
     * Find the currently focused editable node and perform IME Enter on it.
     * API 30+ has ACTION_IME_ENTER; older APIs fall back to ACTION_NEXT
     * or inserting a newline character via ACTION_SET_TEXT (which many apps
     * treat as "submit" on single-line EditTexts).
     */
    internal fun performImeEnterInternal(): Map<String, Any?> {
        val root = rootInActiveWindow ?: return mapOf(
            "success" to false,
            "error" to "no_active_window"
        )

        // Find the focused editable node.
        val focused = findFocusedEditText(root)
        if (focused == null) {
            root.recycle()
            return mapOf(
                "success" to false,
                "error" to "no_focused_editable_node"
            )
        }

        val success = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // API 30+: ACTION_IME_ENTER triggers the keyboard's action button.
            focused.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id)
        } else {
            // Fallback: ACTION_NEXT moves to next field / triggers action on
            // single-line fields in most apps.
            focused.performAction(AccessibilityNodeInfo.ACTION_NEXT_AT_MOVEMENT_GRANULARITY)
                || focused.performAction(AccessibilityNodeInfo.ACTION_CLICK)
        }

        root.recycle()
        return mapOf(
            "success" to success,
            "action" to "ime_enter",
            "api_level" to Build.VERSION.SDK_INT
        )
    }

    internal fun performNodeActionInternal(
        nodeId: Int,
        action: String,
        text: String?,
        direction: String?
    ): Map<String, Any?> {
        val root = rootInActiveWindow ?: return mapOf(
            "success" to false,
            "error" to "no_active_window",
            "message" to "rootInActiveWindow returned null"
        )

        return try {
            val node = findSerializedNodeById(root, nodeId)
            if (node == null) {
                mapOf(
                    "success" to false,
                    "error" to "node_not_found",
                    "node_id" to nodeId
                )
            } else {
                val performed = when (action) {
                    "click" -> node.performAction(AccessibilityNodeInfo.ACTION_CLICK) ||
                            (findClickableParent(node)?.performAction(AccessibilityNodeInfo.ACTION_CLICK) == true)
                    "set_text" -> {
                        val args = Bundle().apply {
                            putCharSequence(
                                AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                                text ?: ""
                            )
                        }
                        node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
                    }
                    "scroll_forward", "scroll_down" ->
                        node.performAction(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD)
                    "scroll_backward", "scroll_up" ->
                        node.performAction(AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD)
                    "focus" -> node.performAction(AccessibilityNodeInfo.ACTION_FOCUS)
                    else -> false
                }
                val bounds = Rect()
                node.getBoundsInScreen(bounds)
                mapOf(
                    "success" to performed,
                    "action" to action,
                    "node_id" to nodeId,
                    "text" to (node.text?.toString() ?: ""),
                    "desc" to (node.contentDescription?.toString() ?: ""),
                    "class" to (node.className?.toString() ?: ""),
                    "package" to (node.packageName?.toString() ?: ""),
                    "bounds" to listOf(bounds.left, bounds.top, bounds.right, bounds.bottom),
                    "direction" to direction
                )
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error performing app-agent action", e)
            mapOf(
                "success" to false,
                "error" to "exception",
                "message" to (e.message ?: "unknown"),
                "node_id" to nodeId,
                "action" to action
            )
        } finally {
            root.recycle()
        }
    }

    /**
     * List all display IDs that currently have accessibility windows.
     */
    internal fun getAvailableDisplaysInternal(): List<Int> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            // Fallback: only primary display
            return if (rootInActiveWindow != null) listOf(0) else emptyList()
        }
        return try {
            val sparse = getWindowsOnAllDisplays()
            (0 until sparse.size()).map { sparse.keyAt(it) }
        } catch (e: Exception) {
            Log.e(TAG, "Error getting displays", e)
            emptyList()
        }
    }

    /**
     * Recursively serialize an AccessibilityNodeInfo into a map structure.
     * Applies pruning: max depth, max total nodes, skips non-interesting nodes.
     */
    private fun serializeNode(
        node: AccessibilityNodeInfo,
        output: MutableList<Map<String, Any?>>,
        depth: Int,
        maxDepth: Int,
        counter: IntArray,
        maxNodes: Int,
        visited: IntArray = intArrayOf(0)
    ) {
        if (depth > maxDepth || counter[0] >= maxNodes) return
        visited[0]++

        val text = node.text?.toString()
        val desc = node.contentDescription?.toString()
        val isClickable = node.isClickable
        val isEditable = node.isEditable
        val isScrollable = node.isScrollable

        // Pruning: skip nodes that have no text, no desc, and are not interactive
        val isInteresting = !text.isNullOrEmpty() || !desc.isNullOrEmpty() ||
                isClickable || isEditable || isScrollable

        if (isInteresting) {
            // Assign an ID FIRST so the ID space is deterministic across all
            // traversals (inspect, find_by_text, findSerializedNodeById). The
            // onscreen filter only decides whether the node appears in the
            // OUTPUT, not whether it consumes an ID slot. This is critical:
            // find_by_text can return id=13 at depth=20 and click(13) must
            // resolve to the SAME node — they share this counter logic.
            val currentId = counter[0]
            counter[0]++

            val bounds = Rect()
            node.getBoundsInScreen(bounds)

            // Filter out invisible/offscreen nodes from the OUTPUT (clean tree
            // for the LLM), but the ID was already consumed above.
            val width = bounds.right - bounds.left
            val height = bounds.bottom - bounds.top
            val screenW = resources.displayMetrics.widthPixels
            val screenH = resources.displayMetrics.heightPixels
            val isOnScreen = width > 0 && height > 0 &&
                    bounds.right > 0 && bounds.bottom > 0 &&
                    bounds.left < screenW && bounds.top < screenH

            if (isOnScreen) {
                val nodeMap = mutableMapOf<String, Any?>(
                    "id" to currentId,
                    "class" to (node.className?.toString() ?: ""),
                    "package" to (node.packageName?.toString() ?: ""),
                    "text" to (text ?: ""),
                    "desc" to (desc ?: ""),
                    "resource_id" to (node.viewIdResourceName ?: ""),
                    "bounds" to listOf(bounds.left, bounds.top, bounds.right, bounds.bottom),
                    "clickable" to isClickable,
                    "editable" to isEditable,
                    "scrollable" to isScrollable,
                    "focused" to node.isFocused,
                    "depth" to depth
                )
                output.add(nodeMap)
            }
        }

        // Recurse into children
        for (i in 0 until node.childCount) {
            if (counter[0] >= maxNodes) break
            val child = node.getChild(i) ?: continue
            serializeNode(child, output, depth + 1, maxDepth, counter, maxNodes, visited)
        }
    }

    private fun findSerializedNodeById(
        node: AccessibilityNodeInfo,
        targetId: Int,
        depth: Int = 0,
        maxDepth: Int = TREE_MAX_DEPTH,
        counter: IntArray = intArrayOf(0),
        maxNodes: Int = TREE_MAX_NODES
    ): AccessibilityNodeInfo? {
        if (depth > maxDepth || counter[0] >= maxNodes) return null

        val text = node.text?.toString()
        val desc = node.contentDescription?.toString()
        val isInteresting = !text.isNullOrEmpty() || !desc.isNullOrEmpty() ||
                node.isClickable || node.isEditable || node.isScrollable

        if (isInteresting) {
            val currentId = counter[0]
            counter[0]++
            if (currentId == targetId) return node
        }

        for (i in 0 until node.childCount) {
            if (counter[0] >= maxNodes) break
            val child = node.getChild(i) ?: continue
            val found = findSerializedNodeById(child, targetId, depth + 1, maxDepth, counter, maxNodes)
            if (found != null) return found
        }
        return null
    }

    private fun windowTypeToString(type: Int): String {
        return when (type) {
            AccessibilityWindowInfo.TYPE_APPLICATION -> "APPLICATION"
            AccessibilityWindowInfo.TYPE_INPUT_METHOD -> "INPUT_METHOD"
            AccessibilityWindowInfo.TYPE_SYSTEM -> "SYSTEM"
            AccessibilityWindowInfo.TYPE_ACCESSIBILITY_OVERLAY -> "ACCESSIBILITY_OVERLAY"
            AccessibilityWindowInfo.TYPE_SPLIT_SCREEN_DIVIDER -> "SPLIT_SCREEN_DIVIDER"
            else -> "UNKNOWN($type)"
        }
    }

    /**
     * Find the package name of the topmost APPLICATION window currently visible.
     * This is more reliable than reading event.packageName because it ignores
     * overlay/IME/system windows and reflects the user's actual active app.
     */
    private fun resolveTopApplicationPackage(): String? {
        return try {
            val windowList = windows ?: return null
            // Find the focused or active APPLICATION window with the highest layer.
            val appWindows = windowList.filter {
                it.type == AccessibilityWindowInfo.TYPE_APPLICATION
            }
            if (appWindows.isEmpty()) return null
            // Prefer the focused/active window, fall back to highest layer.
            val active = appWindows.firstOrNull { it.isActive || it.isFocused }
                ?: appWindows.maxByOrNull { it.layer }
                ?: return null
            val root = active.root ?: return null
            root.packageName?.toString()
        } catch (e: Exception) {
            Log.w(TAG, "resolveTopApplicationPackage failed", e)
            null
        }
    }
}
