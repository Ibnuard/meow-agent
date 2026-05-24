package com.meowagent.meow_agent

import android.app.AppOpsManager
import android.app.NotificationManager
import android.app.usage.UsageStatsManager
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import android.os.BatteryManager
import android.os.Build
import android.os.Environment
import android.os.StatFs
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import androidx.core.content.ContextCompat
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
                "getChargingInfo" -> result.success(getChargingInfo())
                "getDndInfo" -> result.success(getDndInfo())
                "getBluetoothInfo" -> result.success(getBluetoothInfo())
                "getUsageStats" -> {
                    val days = call.argument<Int>("days") ?: 7
                    result.success(getUsageStats(days))
                }
                "setDndMode" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    val mode = call.argument<String>("mode")
                    result.success(setDndMode(enabled, mode))
                }
                "reconnectWifi" -> {
                    result.success(reconnectWifi())
                }
                "getWifiStatus" -> result.success(getWifiStatus())
                "getCellularStatus" -> result.success(getCellularStatus())
                "setBluetoothEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    result.success(setBluetoothEnabled(enabled))
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
            "locale" to getLocaleInfo(),
            "charging" to getChargingInfo(),
            "dnd" to getDndInfo(),
            "bluetooth" to getBluetoothInfo()
        )
    }

    private fun getChargingInfo(): Map<String, Any?> {
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

        val plugged = intent?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0
        val pluggedType = when (plugged) {
            BatteryManager.BATTERY_PLUGGED_USB -> "usb"
            BatteryManager.BATTERY_PLUGGED_AC -> "ac"
            BatteryManager.BATTERY_PLUGGED_WIRELESS -> "wireless"
            4 -> "dock" // BatteryManager.BATTERY_PLUGGED_DOCK (API 33+)
            else -> if (isCharging) "unknown" else "none"
        }

        return mapOf(
            "isCharging" to isCharging,
            "status" to chargingStatus,
            "pluggedType" to pluggedType,
            "level" to percent
        )
    }

    private fun getDndInfo(): Map<String, Any?> {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ?: return mapOf("enabled" to false, "mode" to "unknown", "hasPolicyAccess" to false)

        val hasPolicyAccess = nm.isNotificationPolicyAccessGranted

        val filter = nm.currentInterruptionFilter
        val mode = when (filter) {
            NotificationManager.INTERRUPTION_FILTER_ALL -> "off"
            NotificationManager.INTERRUPTION_FILTER_PRIORITY -> "priority_only"
            NotificationManager.INTERRUPTION_FILTER_ALARMS -> "alarms_only"
            NotificationManager.INTERRUPTION_FILTER_NONE -> "total_silence"
            else -> "unknown"
        }

        val enabled = filter != NotificationManager.INTERRUPTION_FILTER_ALL

        return mapOf(
            "enabled" to enabled,
            "mode" to mode,
            "hasPolicyAccess" to hasPolicyAccess
        )
    }

    private fun setDndMode(enabled: Boolean, mode: String?): Map<String, Any?> {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ?: return mapOf("success" to false, "error" to "NotificationManager unavailable")

        if (!nm.isNotificationPolicyAccessGranted) {
            return mapOf(
                "success" to false,
                "error" to "notification_policy_access_not_granted",
                "hasPolicyAccess" to false
            )
        }

        val filter = if (!enabled) {
            NotificationManager.INTERRUPTION_FILTER_ALL // DND off
        } else {
            when (mode) {
                "priority_only" -> NotificationManager.INTERRUPTION_FILTER_PRIORITY
                "alarms_only" -> NotificationManager.INTERRUPTION_FILTER_ALARMS
                "total_silence" -> NotificationManager.INTERRUPTION_FILTER_NONE
                else -> NotificationManager.INTERRUPTION_FILTER_PRIORITY // default to priority
            }
        }

        return try {
            nm.setInterruptionFilter(filter)
            // Read back current state to confirm.
            val currentFilter = nm.currentInterruptionFilter
            val currentMode = when (currentFilter) {
                NotificationManager.INTERRUPTION_FILTER_ALL -> "off"
                NotificationManager.INTERRUPTION_FILTER_PRIORITY -> "priority_only"
                NotificationManager.INTERRUPTION_FILTER_ALARMS -> "alarms_only"
                NotificationManager.INTERRUPTION_FILTER_NONE -> "total_silence"
                else -> "unknown"
            }
            mapOf(
                "success" to true,
                "enabled" to (currentFilter != NotificationManager.INTERRUPTION_FILTER_ALL),
                "mode" to currentMode
            )
        } catch (e: SecurityException) {
            Log.e(TAG, "setDndMode SecurityException", e)
            mapOf("success" to false, "error" to "security_exception")
        } catch (e: Exception) {
            Log.e(TAG, "setDndMode error", e)
            mapOf("success" to false, "error" to e.message)
        }
    }

    private fun getBluetoothInfo(): Map<String, Any?> {
        // Check BLUETOOTH_CONNECT permission on Android 12+.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val granted = ContextCompat.checkSelfPermission(
                context, android.Manifest.permission.BLUETOOTH_CONNECT
            ) == PackageManager.PERMISSION_GRANTED
            if (!granted) {
                return mapOf(
                    "enabled" to null,
                    "permissionGranted" to false,
                    "connectedDevices" to emptyList<Map<String, Any?>>()
                )
            }
        }

        val bluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        val adapter = bluetoothManager?.adapter
            ?: return mapOf(
                "enabled" to false,
                "permissionGranted" to true,
                "connectedDevices" to emptyList<Map<String, Any?>>()
            )

        val enabled = adapter.isEnabled
        val connectedDevices = mutableListOf<Map<String, Any?>>()

        if (enabled) {
            try {
                // Query common profiles for connected devices.
                val profiles = listOf(
                    BluetoothProfile.HEADSET,
                    BluetoothProfile.A2DP
                )
                for (profile in profiles) {
                    adapter.getProfileProxy(context, object : BluetoothProfile.ServiceListener {
                        override fun onServiceConnected(profileType: Int, proxy: BluetoothProfile) {
                            try {
                                for (device in proxy.connectedDevices) {
                                    val type = when (profileType) {
                                        BluetoothProfile.HEADSET -> "audio"
                                        BluetoothProfile.A2DP -> "audio"
                                        else -> "other"
                                    }
                                    val existing = connectedDevices.any {
                                        it["name"] == (device.name ?: "Unknown")
                                    }
                                    if (!existing) {
                                        connectedDevices.add(mapOf(
                                            "name" to (device.name ?: "Unknown"),
                                            "address" to null,
                                            "type" to type
                                        ))
                                    }
                                }
                            } catch (e: SecurityException) {
                                Log.e(TAG, "SecurityException reading BT devices", e)
                            }
                            adapter.closeProfileProxy(profileType, proxy)
                        }
                        override fun onServiceDisconnected(profileType: Int) {}
                    }, profile)
                }
                // Give profile proxy a moment to connect (best-effort sync approach).
                Thread.sleep(200)
            } catch (e: Exception) {
                Log.e(TAG, "Error reading Bluetooth devices", e)
            }
        }

        return mapOf(
            "enabled" to enabled,
            "permissionGranted" to true,
            "connectedDevices" to connectedDevices.toList()
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

    @Suppress("DEPRECATION")
    private fun getWifiStatus(): Map<String, Any?> {
        return try {
            val wifiManager = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                ?: return mapOf("enabled" to false, "connected" to false, "ssid" to null)

            val enabled = wifiManager.isWifiEnabled
            if (!enabled) {
                return mapOf(
                    "enabled" to false,
                    "connected" to false,
                    "ssid" to null,
                    "signalStrength" to null,
                    "linkSpeed" to null,
                    "frequency" to null,
                    "ip" to null
                )
            }

            val info = try {
                wifiManager.connectionInfo
            } catch (e: SecurityException) {
                Log.w(TAG, "connectionInfo SecurityException: ${e.message}")
                null
            } catch (e: Exception) {
                Log.w(TAG, "connectionInfo error: ${e.message}")
                null
            }

            if (info == null) {
                return mapOf(
                    "enabled" to true,
                    "connected" to false,
                    "ssid" to null,
                    "signalStrength" to null,
                    "linkSpeed" to null,
                    "frequency" to null,
                    "ip" to null
                )
            }

            val connected = info.networkId != -1
            val rawSsid = info.ssid
            val ssid = when {
                !connected -> null
                rawSsid == null -> null
                rawSsid == "<unknown ssid>" -> null
                else -> rawSsid.replace("\"", "")
            }

            val rssi = info.rssi
            val signalLevel = try {
                WifiManager.calculateSignalLevel(rssi, 5)
            } catch (e: Exception) {
                // Best-effort fallback when method is restricted on newer Android.
                when {
                    rssi >= -50 -> 4
                    rssi >= -60 -> 3
                    rssi >= -70 -> 2
                    rssi >= -80 -> 1
                    else -> 0
                }
            }

            val ipInt = info.ipAddress
            val ip = if (ipInt != 0) {
                "${ipInt and 0xFF}.${ipInt shr 8 and 0xFF}.${ipInt shr 16 and 0xFF}.${ipInt shr 24 and 0xFF}"
            } else null

            mapOf(
                "enabled" to true,
                "connected" to connected,
                "ssid" to ssid,
                "signalStrength" to signalLevel,
                "rssi" to rssi,
                "linkSpeed" to info.linkSpeed,
                "frequency" to info.frequency,
                "ip" to ip
            )
        } catch (e: Exception) {
            Log.e(TAG, "getWifiStatus error", e)
            mapOf(
                "enabled" to null,
                "connected" to false,
                "ssid" to null,
                "error" to (e.message ?: "unknown")
            )
        }
    }

    private fun getCellularStatus(): Map<String, Any?> {
        return try {
            val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
                ?: return mapOf("available" to false, "dataConnected" to false, "error" to "ConnectivityManager unavailable")

            val tm = context.getSystemService(Context.TELEPHONY_SERVICE) as? android.telephony.TelephonyManager
                ?: return mapOf("available" to false, "dataConnected" to false, "error" to "TelephonyManager unavailable")

            val network = cm.activeNetwork
            val caps = if (network != null) cm.getNetworkCapabilities(network) else null
            val isCellular = caps?.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) == true

            val dataConnected = try {
                tm.dataState == android.telephony.TelephonyManager.DATA_CONNECTED
            } catch (e: Exception) {
                Log.w(TAG, "dataState error: ${e.message}")
                false
            }

            // dataNetworkType requires READ_PHONE_STATE on Android 10+; may throw SecurityException.
            val networkType = try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    when (tm.dataNetworkType) {
                        android.telephony.TelephonyManager.NETWORK_TYPE_LTE -> "4G/LTE"
                        android.telephony.TelephonyManager.NETWORK_TYPE_NR -> "5G"
                        android.telephony.TelephonyManager.NETWORK_TYPE_HSPAP,
                        android.telephony.TelephonyManager.NETWORK_TYPE_HSPA -> "3G+"
                        android.telephony.TelephonyManager.NETWORK_TYPE_UMTS -> "3G"
                        android.telephony.TelephonyManager.NETWORK_TYPE_EDGE -> "2G/EDGE"
                        android.telephony.TelephonyManager.NETWORK_TYPE_GPRS -> "2G/GPRS"
                        android.telephony.TelephonyManager.NETWORK_TYPE_UNKNOWN -> "unknown"
                        else -> "other"
                    }
                } else "unknown"
            } catch (e: SecurityException) {
                Log.w(TAG, "dataNetworkType SecurityException — needs READ_PHONE_STATE")
                "permission_required"
            } catch (e: Exception) {
                Log.w(TAG, "dataNetworkType error: ${e.message}")
                "unknown"
            }

            val operator = try {
                tm.networkOperatorName ?: "unknown"
            } catch (e: Exception) {
                "unknown"
            }

            val isRoaming = try {
                tm.isNetworkRoaming
            } catch (e: Exception) {
                false
            }

            val simReady = try {
                tm.simState == android.telephony.TelephonyManager.SIM_STATE_READY
            } catch (e: Exception) {
                false
            }

            mapOf(
                "available" to true,
                "simReady" to simReady,
                "dataConnected" to dataConnected,
                "activeTransport" to if (isCellular) "cellular" else "other",
                "networkType" to networkType,
                "operator" to operator,
                "isRoaming" to isRoaming
            )
        } catch (e: Exception) {
            Log.e(TAG, "getCellularStatus error", e)
            mapOf(
                "available" to false,
                "dataConnected" to false,
                "error" to (e.message ?: "unknown")
            )
        }
    }

    @Suppress("DEPRECATION")
    private fun reconnectWifi(): Map<String, Any?> {
        val wifiManager = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            ?: return mapOf("success" to false, "error" to "WifiManager unavailable")

        if (!wifiManager.isWifiEnabled) {
            return mapOf("success" to false, "error" to "wifi_disabled", "message" to "WiFi is currently off. Enable it first.")
        }

        return try {
            // reconnect() triggers reconnection to the current or last configured network.
            val result = wifiManager.reconnect()
            mapOf(
                "success" to result,
                "message" to if (result) "Reconnecting to last known WiFi network." else "Reconnect call failed."
            )
        } catch (e: Exception) {
            Log.e(TAG, "reconnectWifi error", e)
            mapOf("success" to false, "error" to e.message)
        }
    }

    @Suppress("DEPRECATION")
    private fun setBluetoothEnabled(enabled: Boolean): Map<String, Any?> {
        // Check BLUETOOTH_CONNECT permission on Android 12+.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val granted = ContextCompat.checkSelfPermission(
                context, android.Manifest.permission.BLUETOOTH_CONNECT
            ) == PackageManager.PERMISSION_GRANTED
            if (!granted) {
                return mapOf(
                    "success" to false,
                    "error" to "bluetooth_connect_permission_required",
                    "permissionGranted" to false
                )
            }
        }

        val bluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        val adapter = bluetoothManager?.adapter
            ?: return mapOf("success" to false, "error" to "BluetoothAdapter unavailable")

        return try {
            val result = if (enabled) adapter.enable() else adapter.disable()
            mapOf(
                "success" to result,
                "enabled" to enabled,
                "message" to if (result) "Bluetooth ${if (enabled) "enabling" else "disabling"}." else "Toggle failed."
            )
        } catch (e: SecurityException) {
            Log.e(TAG, "setBluetoothEnabled SecurityException", e)
            mapOf("success" to false, "error" to "security_exception")
        } catch (e: Exception) {
            Log.e(TAG, "setBluetoothEnabled error", e)
            mapOf("success" to false, "error" to e.message)
        }
    }
}

