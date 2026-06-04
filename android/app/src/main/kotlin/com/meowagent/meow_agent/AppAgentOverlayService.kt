package com.meowagent.meow_agent

import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.animation.DecelerateInterpolator
import android.widget.FrameLayout
import android.widget.TextView
import androidx.core.content.ContextCompat

/**
 * Dedicated overlay surface for the App Agent automation runtime.
 *
 * Displays two non-focusable / non-touchable system overlays while an
 * App Agent task is in flight:
 *
 *   1. Full-screen colored border indicating the CURRENT operation. The
 *      border color follows a small palette keyed off [Operation] so the
 *      user can glance at the screen and know what stage the agent is in.
 *
 *   2. A narrator bar pinned ~25% from the bottom of the screen showing
 *      a short, real-time progress sentence in the user's language.
 *
 * The overlays never steal focus or input from the foreground app, which
 * means they are safe to render on top of WhatsApp, Telegram, etc. while
 * the accessibility-driven automation reads/acts on the underlying UI.
 *
 * Lifecycle: [show] spawns / updates the views; [hide] tears them down.
 * The service auto-stops on hide; callers must call [show] again to use it.
 */
class AppAgentOverlayService : Service() {

    enum class Operation(val color: Int, val label: String) {
        INSPECT(Color.parseColor("#22C55E"), "Inspecting"),
        CLICK(Color.parseColor("#3B82F6"), "Tapping"),
        SET_TEXT(Color.parseColor("#F59E0B"), "Typing"),
        SCROLL(Color.parseColor("#A855F7"), "Scrolling"),
        OPEN(Color.parseColor("#06B6D4"), "Opening"),
        REVIEW(Color.parseColor("#94A3B8"), "Reviewing"),
        IDLE(Color.parseColor("#64748B"), "");

        companion object {
            fun parse(raw: String?): Operation = when (raw?.lowercase()) {
                "inspect", "app_agent.inspect" -> INSPECT
                "click", "app_agent.click" -> CLICK
                "set_text", "app_agent.set_text", "type" -> SET_TEXT
                "scroll", "app_agent.scroll" -> SCROLL
                "open", "app.open" -> OPEN
                "review" -> REVIEW
                else -> IDLE
            }
        }
    }

    private val TAG = "AppAgentOverlay"
    private var windowManager: WindowManager? = null
    private var borderView: View? = null
    private var narratorContainer: View? = null
    private var narratorText: TextView? = null
    private var currentOperation: Operation = Operation.IDLE

    /** Most recent show() request, deferred until the foreground is non-self. */
    private var pendingOperation: Operation? = null
    private var pendingNarrative: String? = null

    private val handler = Handler(Looper.getMainLooper())

    companion object {
        const val ACTION_SHOW = "com.meowagent.APP_AGENT_OVERLAY_SHOW"
        const val ACTION_HIDE = "com.meowagent.APP_AGENT_OVERLAY_HIDE"
        const val ACTION_FOREGROUND_CHANGED = "com.meowagent.APP_AGENT_OVERLAY_FG"
        const val EXTRA_OPERATION = "operation"
        const val EXTRA_NARRATIVE = "narrative"
        const val EXTRA_PACKAGE = "package"

        @Volatile
        private var instance: AppAgentOverlayService? = null

        fun show(context: Context, operation: String?, narrative: String?) {
            val intent = Intent(context, AppAgentOverlayService::class.java).apply {
                action = ACTION_SHOW
                putExtra(EXTRA_OPERATION, operation)
                putExtra(EXTRA_NARRATIVE, narrative)
            }
            try {
                context.startService(intent)
            } catch (e: Exception) {
                Log.e("AppAgentOverlay", "Failed to start overlay service", e)
            }
        }

        fun hide(context: Context) {
            val intent = Intent(context, AppAgentOverlayService::class.java).apply {
                action = ACTION_HIDE
            }
            try {
                context.startService(intent)
            } catch (_: Exception) {
                // Already gone — no-op.
            }
        }

        /** Called by [MeowAccessibilityService] when the active window changes. */
        fun notifyForegroundChanged(context: Context, packageName: String) {
            val intent = Intent(context, AppAgentOverlayService::class.java).apply {
                action = ACTION_FOREGROUND_CHANGED
                putExtra(EXTRA_PACKAGE, packageName)
            }
            try {
                context.startService(intent)
            } catch (_: Exception) {
                // Service not running yet — nothing to update.
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        windowManager = getSystemService(Context.WINDOW_SERVICE) as WindowManager
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_HIDE -> {
                pendingOperation = null
                pendingNarrative = null
                hideAll()
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_FOREGROUND_CHANGED -> {
                val pkg = intent.getStringExtra(EXTRA_PACKAGE)
                onForegroundChanged(pkg)
            }
            else -> {
                val operationRaw = intent?.getStringExtra(EXTRA_OPERATION)
                val narrative = intent?.getStringExtra(EXTRA_NARRATIVE)
                val op = Operation.parse(operationRaw)
                pendingOperation = op
                pendingNarrative = narrative
                currentOperation = op
                renderIfForeignForeground(op, narrative ?: "")
            }
        }
        return START_STICKY
    }

    /**
     * Render the overlay only when the foreground app is different from
     * Meow Agent itself. Otherwise we buffer the latest request and wait
     * for the next foreground change event.
     */
    private fun renderIfForeignForeground(op: Operation, narrative: String) {
        if (isSelfForeground()) {
            // Defer until the user is in the target app. Hide any leftover
            // surfaces just in case the previous task left them visible.
            hideAll()
            return
        }
        applyBorder(op)
        applyNarrative(narrative, op)
    }

    private fun onForegroundChanged(pkg: String?) {
        if (pkg.isNullOrEmpty()) return
        val pending = pendingOperation
        if (pending == null) {
            // Nothing to show. If the user came back to Meow Agent, tear
            // down anything still floating around.
            if (pkg == packageName) hideAll()
            return
        }
        if (pkg == packageName) {
            // Back inside Meow Agent — overlay should disappear so the
            // launcher / agent UI is unobstructed.
            hideAll()
            return
        }
        applyBorder(pending)
        applyNarrative(pendingNarrative ?: "", pending)
    }

    private fun isSelfForeground(): Boolean {
        val pkg = MeowAccessibilityService.currentForegroundPackage()
        // If unknown (null), assume self — don't render prematurely.
        // The overlay will render once a non-self foreground event arrives
        // from the accessibility service.
        if (pkg == null) return true
        return pkg == packageName
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        super.onDestroy()
        hideAll()
        instance = null
    }

    // ─── Border ──────────────────────────────────────────────────────────

    private fun applyBorder(op: Operation) {
        val wm = windowManager ?: return
        val view = borderView
        if (view != null) {
            (view.background as? GradientDrawable)?.let {
                it.setStroke(dp(3), op.color)
            }
            return
        }

        val frame = FrameLayout(this).apply {
            background = GradientDrawable().apply {
                setStroke(dp(3), op.color)
                setColor(Color.TRANSPARENT)
            }
        }

        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            overlayType(),
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT
        )

        try {
            wm.addView(frame, params)
            borderView = frame
            frame.alpha = 0f
            frame.animate().alpha(1f).setDuration(160).start()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to add border overlay", e)
        }
    }

    // ─── Narrator bar ────────────────────────────────────────────────────

    private fun applyNarrative(narrative: String, op: Operation) {
        val wm = windowManager ?: return

        val container = narratorContainer
        val text = narratorText
        if (container != null && text != null) {
            text.text = narrative
            paintNarratorAccent(container, op)
            return
        }

        // Outer horizontal container: [narrative card] [stop button]
        val row = FrameLayout(this).apply {
            // Transparent background, no padding — just layout.
        }

        val card = FrameLayout(this).apply {
            background = GradientDrawable().apply {
                cornerRadius = dp(18).toFloat()
                setColor(Color.parseColor("#E60F172A"))
                setStroke(dp(1), op.color)
            }
            elevation = 18f
            setPadding(dp(14), dp(10), dp(14), dp(10))
        }

        val tv = TextView(this).apply {
            this.text = narrative
            setTextColor(Color.parseColor("#E5E7EB"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12.5f)
            setLineSpacing(0f, 1.2f)
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            maxLines = 2
        }
        card.addView(
            tv,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.CENTER
            )
        )

        // Stop button
        val stopBtn = TextView(this).apply {
            this.text = "■"
            setTextColor(Color.parseColor("#F87171"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
            typeface = Typeface.DEFAULT_BOLD
            gravity = Gravity.CENTER
            background = GradientDrawable().apply {
                cornerRadius = dp(14).toFloat()
                setColor(Color.parseColor("#CC1E293B"))
                setStroke(dp(1), Color.parseColor("#F87171"))
            }
            setPadding(dp(12), dp(8), dp(12), dp(8))
            isClickable = true
            isFocusable = false
            setOnClickListener { onStopPressed() }
        }

        val screenWidth = resources.displayMetrics.widthPixels
        val cardWidth = (screenWidth * 0.68).toInt().coerceAtMost(dp(360))

        row.addView(card, FrameLayout.LayoutParams(
            cardWidth,
            ViewGroup.LayoutParams.WRAP_CONTENT,
            Gravity.CENTER_VERTICAL or Gravity.START
        ))
        row.addView(stopBtn, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT,
            ViewGroup.LayoutParams.WRAP_CONTENT,
            Gravity.CENTER_VERTICAL or Gravity.END
        ))

        val screenHeight = resources.displayMetrics.heightPixels
        val totalWidth = cardWidth + dp(52)
        val yFromTop = (screenHeight * 0.90).toInt() // ≈10% from bottom

        val params = WindowManager.LayoutParams(
            totalWidth,
            WindowManager.LayoutParams.WRAP_CONTENT,
            overlayType(),
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
            y = yFromTop
        }

        try {
            wm.addView(row, params)
            narratorContainer = row
            narratorText = tv
            row.alpha = 0f
            row.translationY = dp(8).toFloat()
            row.animate()
                .alpha(1f)
                .translationY(0f)
                .setDuration(180)
                .setInterpolator(DecelerateInterpolator())
                .start()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to add narrator overlay", e)
        }
    }

    private fun onStopPressed() {
        // 1. Hide overlay immediately
        pendingOperation = null
        pendingNarrative = null
        hideAll()

        // 2. Signal cancellation to Flutter via broadcast
        val cancelIntent = Intent("com.meowagent.APP_AGENT_CANCEL")
        sendBroadcast(cancelIntent)

        // 3. Bring Meow Agent back to front
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        launchIntent?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        if (launchIntent != null) startActivity(launchIntent)

        stopSelf()
    }

    private fun paintNarratorAccent(card: View?, op: Operation) {
        val bg = card?.background as? GradientDrawable ?: return
        bg.setStroke(dp(1), op.color)
    }

    // ─── Cleanup ─────────────────────────────────────────────────────────

    private fun hideAll() {
        val wm = windowManager
        narratorContainer?.let {
            try { wm?.removeView(it) } catch (_: Exception) {}
        }
        narratorContainer = null
        narratorText = null
        borderView?.let {
            try { wm?.removeView(it) } catch (_: Exception) {}
        }
        borderView = null
    }

    // ─── Utils ───────────────────────────────────────────────────────────

    private fun overlayType(): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        else
            @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE

    private fun dp(value: Int): Int =
        TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP,
            value.toFloat(),
            resources.displayMetrics
        ).toInt()
}
