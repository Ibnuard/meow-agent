package com.meowagent.meow_agent

import android.app.AppOpsManager
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.os.Build
import android.os.Environment
import android.os.StatFs
import android.os.PowerManager
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import java.util.TimeZone

class DeviceContextPlugin(private val context: Context) :
    MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.meowagent/device_context"
        private const val TAG = "DeviceContextPlugin"
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "getBatteryInfo" -> result.success(getBatteryInfo())
                "getNetworkInfo" -> result.success(getNetworkInfo())
                "getStorageInfo" -> result.success(getStorageInfo())
                "getTimeInfo" -> result.success(getTimeInfo())
                "getLocaleInfo" -> result.success(getLocaleInfo())
                "getForegroundAppInfo" -> result.success(getForegroundAppInfo())
                "getDeviceSummary" -> result.success(getDeviceSummary())
                "getUsageStats" -> {
                    val days = call.argument<Int>("days") ?: 7
                    result.success(getUsageStats(days))
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error in ${call.method}", e)
            result.error("DEVICE_CONTEXT_ERROR", e.message, null)
        }
    }

    private fun getBatteryInfo(): Map<String, Any?> {
        val filter = IntentFilter(Intent.ACTION_BATTERY_CHANGED)
        val intent = context.registerReceiver(null, filter)

        val level = intent?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = intent?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
        val percent = if (level >= 0 && scale > 0) (level * 100 / scale) else 0

        val status = intent?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        val isCharging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
                status == BatteryManager.BATTERY_STATUS_FULL
        val chargingStatus = when (status) {
            BatteryManager.BATTERY_STATUS_CHARGING -> "charging"
            BatteryManager.BATTERY_STATUS_DISCHARGING -> "discharging"
            BatteryManager.BATTERY_STATUS_FULL -> "full"
            BatteryManager.BATTERY_STATUS_NOT_CHARGING -> "not_charging"
            else -> "unknown"
        }

        val powerManager = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
        val batterySaver = powerManager?.isPowerSaveMode ?: false

        return mapOf(
            "level" to percent,
            "isCharging" to isCharging,
            "chargingStatus" to chargingStatus,
            "batterySaver" to batterySaver
        )
    }

    private fun getNetworkInfo(): Map<String, Any?> {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return mapOf("isConnected" to false, "type" to "none", "wifiName" to null, "isMetered" to false)

        val network = cm.activeNetwork
        val caps = if (network != null) cm.getNetworkCapabilities(network) else null

        val isConnected = caps != null &&
                caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)

        val type = when {
            caps == null -> "none"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
            else -> "other"
        }

        val isMetered = cm.isActiveNetworkMetered

        // WiFi SSID requires ACCESS_FINE_LOCATION on Android 10+; skip in MVP.
        return mapOf(
            "isConnected" to isConnected,
            "type" to type,
            "wifiName" to null,
            "isMetered" to isMetered
        )
    }

    private fun getStorageInfo(): Map<String, Any?> {
        val stat = StatFs(Environment.getDataDirectory().path)
        val blockSize = stat.blockSizeLong
        val totalBlocks = stat.blockCountLong
        val freeBlocks = stat.availableBlocksLong

        val totalBytes = totalBlocks * blockSize
        val freeBytes = freeBlocks * blockSize
        val usedBytes = totalBytes - freeBytes
        val usedPercent = if (totalBytes > 0) ((usedBytes * 100) / totalBytes).toInt() else 0

        return mapOf(
            "totalBytes" to totalBytes,
            "freeBytes" to freeBytes,
            "usedBytes" to usedBytes,
            "usedPercent" to usedPercent
        )
    }

    private fun getTimeInfo(): Map<String, Any?> {
        val now = Date()
        val tz = TimeZone.getDefault()
        val cal = Calendar.getInstance(tz)

        val sdf = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssXXX", Locale.getDefault())
        sdf.timeZone = tz
        val iso = sdf.format(now)

        return mapOf(
            "iso" to iso,
            "timezone" to tz.id,
            "epochMillis" to cal.timeInMillis
        )
    }

    private fun getLocaleInfo(): Map<String, Any?> {
        val locale = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            context.resources.configuration.locales[0]
        } else {
            @Suppress("DEPRECATION")
            context.resources.configuration.locale
        }

        return mapOf(
            "languageCode" to locale.language,
            "countryCode" to locale.country,
            "locale" to "${locale.language}_${locale.country}"
        )
    }

    private fun getForegroundAppInfo(): Map<String, Any?> {
        // Check PACKAGE_USAGE_STATS permission.
        val appOps = context.getSystemService(Context.APP_OPS_SERVICE) as? AppOpsManager
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            appOps?.unsafeCheckOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                android.os.Process.myUid(),
                context.packageName
            ) ?: AppOpsManager.MODE_DEFAULT
        } else {
            @Suppress("DEPRECATION")
            appOps?.checkOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                android.os.Process.myUid(),
                context.packageName
            ) ?: AppOpsManager.MODE_DEFAULT
        }

        if (mode != AppOpsManager.MODE_ALLOWED) {
            return mapOf("available" to false, "reason" to "permission_required")
        }

        return try {
            val usm = context.getSystemService(Context.USAGE_STATS_SERVICE) as? UsageStatsManager
                ?: return mapOf("available" to false, "reason" to "service_unavailable")

            val now = System.currentTimeMillis()
            val stats = usm.queryUsageStats(
                UsageStatsManager.INTERVAL_DAILY,
                now - 10_000,
                now
            )

            val recent = stats?.maxByOrNull { it.lastTimeUsed }
            if (recent != null) {
                val pm = context.packageManager
                val appName = try {
                    pm.getApplicationLabel(
                        pm.getApplicationInfo(recent.packageName, 0)
                    ).toString()
                } catch (e: Exception) {
                    recent.packageName
                }
                mapOf(
                    "available" to true,
                    "appName" to appName,
                    "packageName" to recent.packageName
                )
            } else {
                mapOf("available" to false, "reason" to "no_data")
            }
        } catch (e: Exception) {
            Log.e(TAG, "getForegroundAppInfo error", e)
            mapOf("available" to false, "reason" to "error")
        }
    }

    private fun getDeviceSummary(): Map<String, Any?> {
        return mapOf(
            "battery" to getBatteryInfo(),
            "network" to getNetworkInfo(),
            "storage" to getStorageInfo(),
            "time" to getTimeInfo(),
            "locale" to getLocaleInfo()
        )
    }

    private fun checkUsagePermission(): Boolean {
        val appOps = context.getSystemService(Context.APP_OPS_SERVICE) as? AppOpsManager
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            appOps?.unsafeCheckOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                android.os.Process.myUid(),
                context.packageName
            ) ?: AppOpsManager.MODE_DEFAULT
        } else {
            @Suppress("DEPRECATION")
            appOps?.checkOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                android.os.Process.myUid(),
                context.packageName
            ) ?: AppOpsManager.MODE_DEFAULT
        }
        return mode == AppOpsManager.MODE_ALLOWED
    }

    private fun getUsageStats(days: Int): Map<String, Any?> {
        if (!checkUsagePermission()) {
            return mapOf("available" to false, "reason" to "permission_required")
        }

        return try {
            val usm = context.getSystemService(Context.USAGE_STATS_SERVICE) as? UsageStatsManager
                ?: return mapOf("available" to false, "reason" to "service_unavailable")

            val now = System.currentTimeMillis()
            val start = now - (days.toLong() * 24 * 60 * 60 * 1000L)

            val stats = usm.queryUsageStats(
                UsageStatsManager.INTERVAL_DAILY, start, now
            )

            val pm = context.packageManager
            val appList = stats
                ?.filter { it.totalTimeInForeground > 0 }
                ?.sortedByDescending { it.totalTimeInForeground }
                ?.mapNotNull { stat ->
                    // Only include apps with a launcher icon (user-facing apps).
                    val hasLauncher = pm.getLaunchIntentForPackage(stat.packageName) != null
                    if (!hasLauncher) return@mapNotNull null
                    val appName = try {
                        pm.getApplicationLabel(
                            pm.getApplicationInfo(stat.packageName, 0)
                        ).toString()
                    } catch (e: Exception) {
                        stat.packageName
                    }
                    mapOf(
                        "appName" to appName,
                        "packageName" to stat.packageName,
                        "totalMinutes" to (stat.totalTimeInForeground / 60_000L)
                    )
                }
                ?.take(10)
                ?: emptyList()

            mapOf(
                "available" to true,
                "days" to days,
                "apps" to appList
            )
        } catch (e: Exception) {
            Log.e(TAG, "getUsageStats error", e)
            mapOf("available" to false, "reason" to "error", "message" to (e.message ?: ""))
        }
    }
}
