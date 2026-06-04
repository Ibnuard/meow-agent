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

        // Track the foreground package for the overlay gating logic. We do
        // this regardless of whether anything is queued so the overlay
        // service can decide when to draw.
        // IMPORTANT: ignore events from our own package — these are triggered
        // by our overlay windows being added/removed and must NOT reset the
        // foreground state (which would cause the overlay to hide itself).
        if (event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
            val pkg = event.packageName?.toString()
            if (!pkg.isNullOrEmpty() && pkg != applicationContext.packageName) {
                foregroundPackage = pkg
                AppAgentOverlayService.notifyForegroundChanged(applicationContext, pkg)
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
                    serializeNode(root, nodes, 0, 15, counter, 200)
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
            serializeNode(root, nodes, 0, 15, counter, 200, visited)

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
            val bounds = Rect()
            node.getBoundsInScreen(bounds)

            val nodeMap = mutableMapOf<String, Any?>(
                "id" to counter[0],
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
            counter[0]++
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
        maxDepth: Int = 15,
        counter: IntArray = intArrayOf(0),
        maxNodes: Int = 200
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
}
