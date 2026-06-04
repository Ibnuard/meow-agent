package com.meowagent.meow_agent

import android.animation.ValueAnimator
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.text.InputType
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.animation.OvershootInterpolator
import android.view.inputmethod.EditorInfo
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import kotlin.math.abs

/**
 * Multi-function floating bubble service (Meow Bubble).
 *
 * States:
 * - IDLE: small draggable dot
 * - MENU: tool selection (Clipboard, Chat)
 * - CHAT: inline chat card with input + response
 * - NARRATING: automation progress text (future)
 */
class FloatingBubbleService : Service() {

    private val TAG = "MeowBubble"
    private var windowManager: WindowManager? = null
    private var bubbleView: View? = null
    private var menuView: View? = null
    private var chatView: View? = null
    private var scrimView: View? = null
    private var layoutParams: WindowManager.LayoutParams? = null
    private var menuShowing = false
    private var chatShowing = false

    // Chat UI references
    private var chatResponseText: TextView? = null
    private var chatHeaderSubtitle: TextView? = null
    private var chatInput: EditText? = null
    private var chatProgress: ProgressBar? = null
    private var chatSendBtn: View? = null

    private val handler = Handler(Looper.getMainLooper())

    companion object {
        const val CHANNEL_ID = "meow_bubble_channel"
        const val NOTIFICATION_ID = 1002
        const val ACTION_STOP = "com.meowagent.STOP_BUBBLE"
        const val ACTION_SHOW_NARRATIVE = "com.meowagent.SHOW_NARRATIVE"
        const val ACTION_CHAT_RESPONSE = "com.meowagent.CHAT_RESPONSE"

        // Static callback for Flutter → Service communication
        var onChatResponse: ((String) -> Unit)? = null
        var onSendMessage: ((String) -> Unit)? = null
        var onRequestInfo: (() -> Unit)? = null

        private var instance: FloatingBubbleService? = null

        /**
         * Called from Flutter side when agent response is ready.
         */
        fun deliverResponse(response: String, header: String? = null) {
            instance?.handler?.post {
                instance?.showChatResponse(response, header)
            }
        }

        /**
         * Show narrative progress text in the chat response area (while loading).
         */
        fun showNarrativeText(text: String) {
            instance?.handler?.post {
                instance?.chatResponseText?.text = text
                instance?.chatResponseText?.setTextColor(Color.parseColor("#94A3B8"))
            }
        }

        /**
         * Show narrative text on the bubble (for automation progress).
         */
        fun showNarrative(text: String) {
            instance?.handler?.post {
                // Future: show narrative mode on collapsed bubble
                Log.d("MeowBubble", "Narrative: $text")
            }
        }

        /**
         * Update chat header with agent/model info.
         */
        fun updateChatInfo(info: String) {
            instance?.handler?.post {
                instance?.chatHeaderSubtitle?.text = info
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        Log.d(TAG, "Service onCreate")
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_CHAT_RESPONSE -> {
                val response = intent.getStringExtra("response") ?: ""
                showChatResponse(response)
                return START_STICKY
            }
        }

        startForeground(NOTIFICATION_ID, buildNotification())
        showBubble()
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        super.onDestroy()
        instance = null
        Log.d(TAG, "Service onDestroy")
        dismissMenu()
        dismissChat()
        removeBubble()
    }

    // ─── Notification ───────────────────────────────────────────────────

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Meow Bubble",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Floating bubble for quick AI actions"
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
            .setContentText("Tap bubble for quick actions")
            .setSmallIcon(android.R.drawable.ic_menu_view)
            .setOngoing(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Stop", stopPending)
            .build()
    }

    // ─── Bubble View ────────────────────────────────────────────────────

    private fun showBubble() {
        if (bubbleView != null) return
        Log.d(TAG, "Showing bubble")

        windowManager = getSystemService(Context.WINDOW_SERVICE) as WindowManager

        val container = FrameLayout(this).apply {
            background = ContextCompat.getDrawable(
                this@FloatingBubbleService, R.drawable.bubble_background
            )
            elevation = 12f
        }

        val icon = ImageView(this).apply {
            setImageResource(android.R.drawable.ic_menu_compass)
            setColorFilter(Color.WHITE)
            val padding = dp(12)
            setPadding(padding, padding, padding, padding)
        }
        container.addView(icon)

        val sizePx = dp(52)

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
            x = resources.displayMetrics.widthPixels - sizePx - dp(8)
            y = resources.displayMetrics.heightPixels / 3
        }

        attachDragAndTap(container)

        try {
            windowManager?.addView(container, layoutParams)
            bubbleView = container
        } catch (e: Exception) {
            Log.e(TAG, "Failed to add bubble view", e)
        }
    }

    // ─── Drag & Tap ─────────────────────────────────────────────────────

    private fun attachDragAndTap(view: View) {
        var initialX = 0
        var initialY = 0
        var touchX = 0f
        var touchY = 0f
        var isDragging = false
        val tapThreshold = dp(8).toFloat()

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
                        v.performClick()
                        if (chatShowing) {
                            dismissChat()
                        } else {
                            toggleMenu()
                        }
                    } else {
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

        val targetX = if (params.x + bubbleWidth / 2 < mid) dp(8) else screenWidth - bubbleWidth - dp(8)

        val startX = params.x
        ValueAnimator.ofInt(startX, targetX).apply {
            duration = 200
            addUpdateListener {
                params.x = it.animatedValue as Int
                try { windowManager?.updateViewLayout(view, params) } catch (_: Exception) {}
            }
            start()
        }
    }

    // ─── Tool Menu ──────────────────────────────────────────────────────

    private fun toggleMenu() {
        if (menuShowing) dismissMenu() else showMenu()
    }

    private fun showMenu() {
        if (menuShowing) return
        menuShowing = true

        val wm = windowManager ?: return
        val bubbleParams = layoutParams ?: return

        // Scrim
        scrimView = View(this).apply {
            setBackgroundColor(Color.parseColor("#40000000"))
            alpha = 0f
            setOnClickListener { dismissMenu() }
        }
        val scrimParams = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            overlayType(),
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        )
        try { wm.addView(scrimView, scrimParams) } catch (e: Exception) {
            Log.e(TAG, "Failed to add scrim", e)
        }

        // Menu card
        val menuLayout = buildMenuLayout()
        menuView = menuLayout

        val menuWidth = dp(200)
        val screenWidth = resources.displayMetrics.widthPixels
        val isRight = bubbleParams.x > screenWidth / 2
        val menuX = if (isRight) bubbleParams.x - menuWidth + dp(52) else bubbleParams.x
        val menuY = bubbleParams.y - dp(140)

        val menuParams = WindowManager.LayoutParams(
            menuWidth,
            WindowManager.LayoutParams.WRAP_CONTENT,
            overlayType(),
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = menuX
            y = menuY
        }

        try { wm.addView(menuLayout, menuParams) } catch (e: Exception) {
            Log.e(TAG, "Failed to add menu", e)
        }

        // Animate in
        scrimView?.animate()?.alpha(1f)?.setDuration(200)?.start()
        menuLayout.alpha = 0f
        menuLayout.scaleX = 0.8f
        menuLayout.scaleY = 0.8f
        menuLayout.animate()
            .alpha(1f).scaleX(1f).scaleY(1f)
            .setDuration(250)
            .setInterpolator(OvershootInterpolator(1.2f))
            .start()
    }

    private fun dismissMenu() {
        if (!menuShowing) return
        menuShowing = false
        val wm = windowManager ?: return

        menuView?.animate()?.alpha(0f)?.scaleX(0.8f)?.scaleY(0.8f)
            ?.setDuration(150)
            ?.withEndAction {
                try { menuView?.let { wm.removeView(it) } } catch (_: Exception) {}
                menuView = null
            }?.start()

        scrimView?.animate()?.alpha(0f)?.setDuration(150)
            ?.withEndAction {
                try { scrimView?.let { wm.removeView(it) } } catch (_: Exception) {}
                scrimView = null
            }?.start()
    }

    private fun buildMenuLayout(): View {
        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = ContextCompat.getDrawable(
                this@FloatingBubbleService, R.drawable.bubble_menu_background
            )
            elevation = 24f
            setPadding(dp(12), dp(14), dp(12), dp(14))
        }

        val title = TextView(this).apply {
            text = "Meow Agent"
            setTextColor(Color.parseColor("#94A3B8"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            val lp = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT
            )
            lp.bottomMargin = dp(8)
            lp.leftMargin = dp(6)
            layoutParams = lp
        }
        container.addView(title)

        container.addView(buildMenuItem("📋", "Clipboard AI") {
            dismissMenu()
            launchClipboard()
        })
        container.addView(buildMenuItem("💬", "Quick Chat") {
            dismissMenu()
            showChat()
        })

        return container
    }

    private fun buildMenuItem(emoji: String, label: String, onClick: () -> Unit): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = ContextCompat.getDrawable(
                this@FloatingBubbleService, R.drawable.bubble_menu_item_bg
            )
            setPadding(dp(14), dp(11), dp(14), dp(11))
            val lp = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT
            )
            lp.topMargin = dp(4)
            layoutParams = lp
            setOnClickListener { onClick() }
            isClickable = true
            isFocusable = true
        }

        row.addView(TextView(this).apply {
            text = emoji
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
            val lp = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT
            )
            lp.rightMargin = dp(12)
            layoutParams = lp
        })

        row.addView(TextView(this).apply {
            text = label
            setTextColor(Color.parseColor("#E5E7EB"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        })

        return row
    }

    // ─── Inline Chat Card ───────────────────────────────────────────────

    private fun showChat() {
        if (chatShowing) return
        chatShowing = true

        val wm = windowManager ?: return
        val bubbleParams = layoutParams ?: return

        val chatCard = buildChatCard()
        chatView = chatCard

        val screenWidth = resources.displayMetrics.widthPixels
        val chatWidth = (screenWidth * 0.82).toInt()
        val chatX = (screenWidth - chatWidth) / 2
        val chatY = bubbleParams.y - dp(60)

        val chatParams = WindowManager.LayoutParams(
            chatWidth,
            WindowManager.LayoutParams.WRAP_CONTENT,
            overlayType(),
            // FLAG_NOT_TOUCH_MODAL allows input to work; FLAG_WATCH_OUTSIDE_TOUCH for dismiss
            WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                    WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = chatX
            y = chatY
            softInputMode = WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE
        }

        try { wm.addView(chatCard, chatParams) } catch (e: Exception) {
            Log.e(TAG, "Failed to add chat card", e)
            chatShowing = false
            return
        }

        // Animate in
        chatCard.alpha = 0f
        chatCard.translationY = dp(20).toFloat()
        chatCard.animate()
            .alpha(1f)
            .translationY(0f)
            .setDuration(250)
            .setInterpolator(OvershootInterpolator(1.0f))
            .start()

        // Focus input
        handler.postDelayed({ chatInput?.requestFocus() }, 300)

        // Request agent/model info from Flutter
        onRequestInfo?.invoke()
    }

    private fun dismissChat() {
        if (!chatShowing) return
        chatShowing = false
        val wm = windowManager ?: return

        chatView?.animate()
            ?.alpha(0f)
            ?.translationY(dp(20).toFloat())
            ?.setDuration(150)
            ?.withEndAction {
                try { chatView?.let { wm.removeView(it) } } catch (_: Exception) {}
                chatView = null
                chatResponseText = null
                chatInput = null
                chatProgress = null
                chatSendBtn = null
            }?.start()
    }

    private fun buildChatCard(): View {
        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = ContextCompat.getDrawable(
                this@FloatingBubbleService, R.drawable.bubble_menu_background
            )
            elevation = 24f
            setPadding(dp(16), dp(16), dp(16), dp(16))
        }

        // Header
        val headerContainer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            val lp = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT
            )
            lp.bottomMargin = dp(12)
            layoutParams = lp
        }

        val headerRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }

        headerRow.addView(TextView(this).apply {
            text = "💬 Quick Chat"
            setTextColor(Color.parseColor("#E5E7EB"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            typeface = Typeface.create("sans-serif-medium", Typeface.BOLD)
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        })

        headerRow.addView(TextView(this).apply {
            text = "✕"
            setTextColor(Color.parseColor("#64748B"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
            setPadding(dp(8), dp(4), dp(4), dp(4))
            setOnClickListener { dismissChat() }
        })

        headerContainer.addView(headerRow)

        // Subtitle: agent name + model
        chatHeaderSubtitle = TextView(this).apply {
            text = "Loading..."
            setTextColor(Color.parseColor("#3B82F6"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
            val lp = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT
            )
            lp.topMargin = dp(4)
            layoutParams = lp
        }
        headerContainer.addView(chatHeaderSubtitle)

        card.addView(headerContainer)

        // Response area (scrollable)
        val scrollView = ScrollView(this).apply {
            val lp = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(120)
            )
            lp.bottomMargin = dp(12)
            layoutParams = lp
        }

        chatResponseText = TextView(this).apply {
            text = "Ask me anything..."
            setTextColor(Color.parseColor("#94A3B8"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            setLineSpacing(0f, 1.4f)
            setPadding(dp(4), dp(4), dp(4), dp(4))
        }
        scrollView.addView(chatResponseText)
        card.addView(scrollView)

        // Progress bar (hidden by default)
        chatProgress = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            isIndeterminate = true
            visibility = View.GONE
            val lp = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(3)
            )
            lp.bottomMargin = dp(8)
            layoutParams = lp
        }
        card.addView(chatProgress)

        // Input row
        val inputRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }

        chatInput = EditText(this).apply {
            hint = "Type a message..."
            setHintTextColor(Color.parseColor("#64748B"))
            setTextColor(Color.parseColor("#E5E7EB"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            setBackgroundColor(Color.parseColor("#1A1F2E"))
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
            imeOptions = EditorInfo.IME_ACTION_SEND
            maxLines = 3
            setPadding(dp(14), dp(10), dp(14), dp(10))
            layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)

            // Handle IME send action
            setOnEditorActionListener { _, actionId, event ->
                if (actionId == EditorInfo.IME_ACTION_SEND ||
                    (event?.keyCode == KeyEvent.KEYCODE_ENTER && event.action == KeyEvent.ACTION_DOWN)) {
                    sendChatMessage()
                    true
                } else false
            }
        }
        inputRow.addView(chatInput)

        // Send button
        chatSendBtn = FrameLayout(this).apply {
            val size = dp(40)
            layoutParams = LinearLayout.LayoutParams(size, size).apply {
                leftMargin = dp(8)
            }
            background = ContextCompat.getDrawable(
                this@FloatingBubbleService, R.drawable.bubble_background
            )
            elevation = 4f

            val sendIcon = ImageView(this@FloatingBubbleService).apply {
                setImageResource(android.R.drawable.ic_menu_send)
                setColorFilter(Color.WHITE)
                val p = dp(9)
                setPadding(p, p, p, p)
            }
            addView(sendIcon)
            setOnClickListener { sendChatMessage() }
        }
        inputRow.addView(chatSendBtn)

        card.addView(inputRow)

        // Handle outside touch to dismiss
        card.setOnTouchListener { _, event ->
            if (event.action == MotionEvent.ACTION_OUTSIDE) {
                dismissChat()
                true
            } else false
        }

        return card
    }

    private fun sendChatMessage() {
        val message = chatInput?.text?.toString()?.trim() ?: return
        if (message.isEmpty()) return

        Log.d(TAG, "Sending chat: $message")

        // Update UI
        chatInput?.text?.clear()
        chatResponseText?.text = ""
        chatResponseText?.setTextColor(Color.parseColor("#E5E7EB"))
        chatProgress?.visibility = View.VISIBLE
        chatSendBtn?.isEnabled = false

        // Send to Flutter via static callback
        onSendMessage?.invoke(message)
    }

    private fun showChatResponse(response: String, header: String? = null) {
        Log.d(TAG, "Showing response: ${response.take(50)}")
        chatProgress?.visibility = View.GONE
        chatSendBtn?.isEnabled = true

        if (chatShowing && chatResponseText != null) {
            chatResponseText?.text = response
            chatResponseText?.setTextColor(Color.parseColor("#E5E7EB"))
        }
    }

    // ─── Actions ────────────────────────────────────────────────────────

    private fun launchClipboard() {
        Log.d(TAG, "Launching Clipboard AI")
        val intent = Intent(this, MainActivity::class.java).apply {
            action = ClipboardForegroundService.ACTION_PROCESS
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        startActivity(intent)
    }

    // ─── Cleanup ────────────────────────────────────────────────────────

    private fun removeBubble() {
        bubbleView?.let {
            try { windowManager?.removeView(it) } catch (_: Exception) {}
        }
        bubbleView = null
    }

    // ─── Utils ──────────────────────────────────────────────────────────

    private fun overlayType(): Int {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        else
            @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE
    }

    private fun dp(value: Int): Int {
        return (value * resources.displayMetrics.density).toInt()
    }
}
