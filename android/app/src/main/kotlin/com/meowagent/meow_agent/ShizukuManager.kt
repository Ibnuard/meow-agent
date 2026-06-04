package com.meowagent.meow_agent

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import rikka.shizuku.Shizuku
import java.io.BufferedReader
import java.io.InputStreamReader

/**
 * ShizukuManager — ADB-level shell access for device automation.
 *
 * Provides:
 * - Shell command execution (input keyevent, input tap, input text, etc.)
 * - Wake screen, unlock device, lock device
 * - Permission management for Shizuku runtime grant
 *
 * Requires: Shizuku app installed and service running on device.
 */
class ShizukuManager(private val context: Context) {

    companion object {
        private const val TAG = "ShizukuMgr"
        private const val SHIZUKU_PERMISSION_CODE = 1001
    }

    // ─── Status Checks ──────────────────────────────────────────────────

    /**
     * Check if Shizuku service is running and reachable.
     */
    fun isShizukuAvailable(): Boolean {
        return try {
            Shizuku.pingBinder()
        } catch (e: Exception) {
            Log.w(TAG, "Shizuku ping failed: ${e.message}")
            false
        }
    }

    /**
     * Check if our app has been granted Shizuku permission.
     */
    fun hasPermission(): Boolean {
        return try {
            if (!isShizukuAvailable()) return false
            Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
        } catch (e: Exception) {
            Log.w(TAG, "Permission check failed: ${e.message}")
            false
        }
    }

    /**
     * Request Shizuku permission. The user sees a confirmation dialog from Shizuku app.
     */
    fun requestPermission() {
        try {
            if (!isShizukuAvailable()) {
                Log.w(TAG, "Cannot request permission — Shizuku not available")
                return
            }
            Shizuku.requestPermission(SHIZUKU_PERMISSION_CODE)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to request Shizuku permission", e)
        }
    }

    /**
     * Register a listener for permission result.
     */
    fun addPermissionListener(listener: (Int, Int) -> Unit) {
        Shizuku.addRequestPermissionResultListener { requestCode, grantResult ->
            listener(requestCode, grantResult)
        }
    }

    // ─── Shell Execution ────────────────────────────────────────────────

    /**
     * Execute a shell command via Shizuku (runs as UID 2000 / shell).
     * Uses reflection to access Shizuku.newProcess (private in API 13.x).
     * Returns the command output as string, or error message.
     */
    fun exec(command: String): ShellResult {
        if (!hasPermission()) {
            return ShellResult(
                success = false,
                output = "",
                error = "Shizuku permission not granted"
            )
        }

        return try {
            // Shizuku.newProcess is private in API 13.x — use reflection.
            val method = Shizuku::class.java.getDeclaredMethod(
                "newProcess",
                Array<String>::class.java,
                Array<String>::class.java,
                String::class.java
            )
            method.isAccessible = true
            val process = method.invoke(
                null,
                arrayOf("sh", "-c", command),
                null,
                null
            ) as Process

            val stdout = BufferedReader(InputStreamReader(process.inputStream)).readText()
            val stderr = BufferedReader(InputStreamReader(process.errorStream)).readText()
            val exitCode = process.waitFor()

            Log.d(TAG, "exec [$command] → exit=$exitCode, out=${stdout.take(100)}")

            ShellResult(
                success = exitCode == 0,
                output = stdout.trim(),
                error = stderr.trim(),
                exitCode = exitCode
            )
        } catch (e: Exception) {
            Log.e(TAG, "Shell exec failed: $command", e)
            ShellResult(
                success = false,
                output = "",
                error = e.message ?: "Unknown error"
            )
        }
    }

    // ─── Device Control ─────────────────────────────────────────────────

    /**
     * Wake the screen (equivalent to pressing power button when off).
     */
    fun wakeScreen(): ShellResult {
        return exec("input keyevent KEYCODE_WAKEUP")
    }

    /**
     * Check if the screen is currently on.
     */
    fun isScreenOn(): Boolean {
        val result = exec("dumpsys power | grep 'Display Power'")
        return result.output.contains("state=ON")
    }

    /**
     * Check if the device is currently locked (keyguard showing).
     */
    fun isDeviceLocked(): Boolean {
        val result = exec("dumpsys window | grep 'mDreamingLockscreen'")
        if (result.output.contains("mDreamingLockscreen=true")) return true
        // Fallback check
        val result2 = exec("dumpsys window | grep 'isKeyguardShowing'")
        return result2.output.contains("isKeyguardShowing=true")
    }

    /**
     * Swipe up to reveal PIN/password entry (from lock screen).
     * Coordinates are for a typical 1080x2400 screen — adjust if needed.
     */
    fun swipeUp(
        startX: Int = 540,
        startY: Int = 1800,
        endX: Int = 540,
        endY: Int = 800,
        durationMs: Int = 300
    ): ShellResult {
        return exec("input swipe $startX $startY $endX $endY $durationMs")
    }

    /**
     * Type text via shell input (used for PIN entry).
     */
    fun inputText(text: String): ShellResult {
        // Escape special characters for shell
        val escaped = text.replace("'", "'\\''")
        return exec("input text '$escaped'")
    }

    /**
     * Press a keycode (e.g., ENTER=66, BACK=4, HOME=3, POWER=26).
     */
    fun pressKey(keycode: Int): ShellResult {
        return exec("input keyevent $keycode")
    }

    /**
     * Tap at screen coordinates.
     */
    fun tap(x: Int, y: Int): ShellResult {
        return exec("input tap $x $y")
    }

    /**
     * Lock the device (power button press).
     */
    fun lockDevice(): ShellResult {
        return exec("input keyevent 26")
    }

    /**
     * Full wake + unlock sequence.
     * Returns detailed step-by-step results.
     */
    fun wakeAndUnlock(pin: String): Map<String, Any?> {
        val steps = mutableMapOf<String, Any?>()

        // Step 1: Check if already unlocked
        val screenOn = isScreenOn()
        val locked = isDeviceLocked()
        steps["initial_screen_on"] = screenOn
        steps["initial_locked"] = locked

        if (screenOn && !locked) {
            steps["action"] = "already_unlocked"
            steps["success"] = true
            return steps
        }

        // Step 2: Wake screen if off
        if (!screenOn) {
            val wake = wakeScreen()
            steps["step_1_wake"] = wake.toMap()
            if (!wake.success) {
                steps["error"] = "wake_failed"
                steps["success"] = false
                return steps
            }
            // Wait for screen to turn on
            Thread.sleep(500)
        }

        // Step 3: Swipe up to show PIN entry
        val swipe = swipeUp()
        steps["step_2_swipe"] = swipe.toMap()
        Thread.sleep(500)

        // Step 4: Enter PIN
        if (pin.isNotEmpty()) {
            val text = inputText(pin)
            steps["step_3_pin_entry"] = text.toMap()
            Thread.sleep(200)

            // Step 5: Press ENTER to confirm
            val enter = pressKey(66) // KEYCODE_ENTER
            steps["step_4_enter"] = enter.toMap()
            Thread.sleep(1000)
        }

        // Step 6: Verify unlock
        val stillLocked = isDeviceLocked()
        steps["final_locked"] = stillLocked
        steps["success"] = !stillLocked

        if (stillLocked) {
            steps["error"] = "unlock_failed_still_locked"
        }

        return steps
    }

    /**
     * Get comprehensive status info for debugging.
     */
    fun getStatus(): Map<String, Any?> {
        return mapOf(
            "shizuku_available" to isShizukuAvailable(),
            "permission_granted" to hasPermission(),
            "shizuku_version" to try { Shizuku.getVersion() } catch (e: Exception) { -1 },
            "screen_on" to try { isScreenOn() } catch (e: Exception) { null },
            "device_locked" to try { isDeviceLocked() } catch (e: Exception) { null },
            "android_api" to Build.VERSION.SDK_INT
        )
    }

    data class ShellResult(
        val success: Boolean,
        val output: String,
        val error: String,
        val exitCode: Int = -1
    ) {
        fun toMap(): Map<String, Any?> = mapOf(
            "success" to success,
            "output" to output,
            "error" to error,
            "exit_code" to exitCode
        )
    }
}
