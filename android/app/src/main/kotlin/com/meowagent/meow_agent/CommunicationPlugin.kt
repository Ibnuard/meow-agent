package com.meowagent.meow_agent

import android.Manifest
import android.content.ContentResolver
import android.content.Intent
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.provider.ContactsContract
import android.telecom.TelecomManager
import android.telephony.SmsManager
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Native communication handler for Meow Agent.
 *
 * Handles: contact resolution, phone calls, SMS, and WhatsApp automation
 * via Accessibility Service.
 *
 * All permission checks are done here — returns clear error if missing.
 */
class CommunicationPlugin(private val activity: FlutterActivity) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.meowagent/communication"
        private const val TAG = "MeowComm"
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "resolveContact" -> resolveContact(call, result)
                "listContacts" -> listContacts(call, result)
                "sendWhatsApp" -> sendWhatsApp(call, result)
                "sendWhatsAppGroup" -> sendWhatsAppGroup(call, result)
                "waVoiceCall" -> waVoiceCall(call, result)
                "waVideoCall" -> waVideoCall(call, result)
                "makeCall" -> makeCall(call, result)
                "sendSms" -> sendSms(call, result)
                "isAccessibilityEnabled" -> {
                    result.success(MeowAccessibilityService.isEnabled(activity))
                }
                "openAccessibilitySettings" -> {
                    val intent = Intent(android.provider.Settings.ACTION_ACCESSIBILITY_SETTINGS)
                    intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
                    activity.startActivity(intent)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error in ${call.method}: ${e.message}", e)
            result.error("COMMUNICATION_ERROR", e.message, null)
        }
    }

    // ─── Contact Resolution ──────────────────────────────────────────

    private fun resolveContact(call: MethodCall, result: MethodChannel.Result) {
        if (!hasPermission(Manifest.permission.READ_CONTACTS)) {
            result.error("PERMISSION_DENIED", "READ_CONTACTS permission not granted.", null)
            return
        }

        val query = call.argument<String>("query") ?: ""
        val contacts = searchContacts(query, 5)

        if (contacts.isEmpty()) {
            result.success(mapOf("found" to false, "query" to query))
        } else {
            val best = contacts.first()
            result.success(mapOf(
                "found" to true,
                "name" to best["name"],
                "phone" to best["phone"],
                "all_matches" to contacts
            ))
        }
    }

    private fun listContacts(call: MethodCall, result: MethodChannel.Result) {
        if (!hasPermission(Manifest.permission.READ_CONTACTS)) {
            result.error("PERMISSION_DENIED", "READ_CONTACTS permission not granted.", null)
            return
        }

        val query = call.argument<String>("query") ?: ""
        val limit = call.argument<Int>("limit") ?: 20
        val contacts = searchContacts(query, limit)
        result.success(contacts)
    }

    private fun searchContacts(query: String, limit: Int): List<Map<String, String>> {
        val resolver: ContentResolver = activity.contentResolver
        val results = mutableListOf<Map<String, String>>()

        val uri = ContactsContract.CommonDataKinds.Phone.CONTENT_URI
        val projection = arrayOf(
            ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
            ContactsContract.CommonDataKinds.Phone.NUMBER
        )

        val selection = if (query.isNotEmpty()) {
            "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} LIKE ?"
        } else null

        val selectionArgs = if (query.isNotEmpty()) {
            arrayOf("%$query%")
        } else null

        val sortOrder = "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} ASC"

        var cursor: Cursor? = null
        try {
            cursor = resolver.query(uri, projection, selection, selectionArgs, sortOrder)
            if (cursor != null) {
                val nameIdx = cursor.getColumnIndex(ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME)
                val phoneIdx = cursor.getColumnIndex(ContactsContract.CommonDataKinds.Phone.NUMBER)
                var count = 0
                while (cursor.moveToNext() && count < limit) {
                    val name = cursor.getString(nameIdx) ?: continue
                    val phone = cursor.getString(phoneIdx) ?: continue
                    results.add(mapOf("name" to name, "phone" to phone.replace("\\s".toRegex(), "")))
                    count++
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error searching contacts: ${e.message}", e)
        } finally {
            cursor?.close()
        }

        return results
    }

    // ─── WhatsApp Messaging ──────────────────────────────────────────

    private fun sendWhatsApp(call: MethodCall, result: MethodChannel.Result) {
        if (!ensureAccessibility(result)) return

        val phone = call.argument<String>("phone") ?: ""
        val message = call.argument<String>("message") ?: ""

        // Queue the action in the accessibility service.
        MeowAccessibilityService.queueAction(
            MeowAccessibilityAction.SendWhatsApp(phone = phone, message = message)
        )

        // Launch WhatsApp chat via deep link.
        val cleanPhone = phone.replace("+", "").replace(" ", "")
        val uri = Uri.parse("https://wa.me/$cleanPhone?text=${Uri.encode(message)}")
        val intent = Intent(Intent.ACTION_VIEW, uri).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK
        }

        try {
            activity.startActivity(intent)
            result.success(mapOf("success" to true, "phone" to phone, "message" to message))
        } catch (e: Exception) {
            result.success(mapOf("success" to false, "error" to "Failed to open WhatsApp: ${e.message}"))
        }
    }

    private fun sendWhatsAppGroup(call: MethodCall, result: MethodChannel.Result) {
        if (!ensureAccessibility(result)) return

        val groupName = call.argument<String>("group_name") ?: ""
        val message = call.argument<String>("message") ?: ""

        // Queue group message action.
        MeowAccessibilityService.queueAction(
            MeowAccessibilityAction.SendWhatsAppGroup(groupName = groupName, message = message)
        )

        // Open WhatsApp main screen — accessibility service will find the group.
        val intent = activity.packageManager.getLaunchIntentForPackage("com.whatsapp")
        if (intent != null) {
            intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
            activity.startActivity(intent)
            result.success(mapOf("success" to true, "group" to groupName, "message" to message))
        } else {
            result.success(mapOf("success" to false, "error" to "WhatsApp is not installed."))
        }
    }

    // ─── WhatsApp Calling ────────────────────────────────────────────

    private fun waVoiceCall(call: MethodCall, result: MethodChannel.Result) {
        if (!ensureAccessibility(result)) return

        val phone = call.argument<String>("phone") ?: ""
        MeowAccessibilityService.queueAction(
            MeowAccessibilityAction.WaCall(phone = phone, video = false)
        )

        // Open WA chat — accessibility will tap call button.
        val cleanPhone = phone.replace("+", "").replace(" ", "")
        val uri = Uri.parse("https://wa.me/$cleanPhone")
        val intent = Intent(Intent.ACTION_VIEW, uri).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK
        }

        try {
            activity.startActivity(intent)
            result.success(mapOf("success" to true, "phone" to phone, "type" to "voice"))
        } catch (e: Exception) {
            result.success(mapOf("success" to false, "error" to "Failed to open WhatsApp: ${e.message}"))
        }
    }

    private fun waVideoCall(call: MethodCall, result: MethodChannel.Result) {
        if (!ensureAccessibility(result)) return

        val phone = call.argument<String>("phone") ?: ""
        MeowAccessibilityService.queueAction(
            MeowAccessibilityAction.WaCall(phone = phone, video = true)
        )

        val cleanPhone = phone.replace("+", "").replace(" ", "")
        val uri = Uri.parse("https://wa.me/$cleanPhone")
        val intent = Intent(Intent.ACTION_VIEW, uri).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK
        }

        try {
            activity.startActivity(intent)
            result.success(mapOf("success" to true, "phone" to phone, "type" to "video"))
        } catch (e: Exception) {
            result.success(mapOf("success" to false, "error" to "Failed to open WhatsApp: ${e.message}"))
        }
    }

    // ─── Phone Call ──────────────────────────────────────────────────

    private fun makeCall(call: MethodCall, result: MethodChannel.Result) {
        if (!hasPermission(Manifest.permission.CALL_PHONE)) {
            result.error("PERMISSION_DENIED", "CALL_PHONE permission not granted.", null)
            return
        }

        val phone = call.argument<String>("phone") ?: ""
        val intent = Intent(Intent.ACTION_CALL).apply {
            data = Uri.parse("tel:$phone")
            flags = Intent.FLAG_ACTIVITY_NEW_TASK
        }

        try {
            activity.startActivity(intent)
            result.success(mapOf("success" to true, "phone" to phone))
        } catch (e: Exception) {
            result.success(mapOf("success" to false, "error" to "Failed to make call: ${e.message}"))
        }
    }

    // ─── SMS ─────────────────────────────────────────────────────────

    private fun sendSms(call: MethodCall, result: MethodChannel.Result) {
        if (!hasPermission(Manifest.permission.SEND_SMS)) {
            result.error("PERMISSION_DENIED", "SEND_SMS permission not granted.", null)
            return
        }

        val phone = call.argument<String>("phone") ?: ""
        val message = call.argument<String>("message") ?: ""

        try {
            val smsManager = activity.getSystemService(SmsManager::class.java)
            smsManager.sendTextMessage(phone, null, message, null, null)
            result.success(mapOf("success" to true, "phone" to phone, "message" to message))
        } catch (e: Exception) {
            result.success(mapOf("success" to false, "error" to "Failed to send SMS: ${e.message}"))
        }
    }

    // ─── Helpers ─────────────────────────────────────────────────────

    private fun hasPermission(permission: String): Boolean {
        return ContextCompat.checkSelfPermission(activity, permission) ==
                PackageManager.PERMISSION_GRANTED
    }

    private fun ensureAccessibility(result: MethodChannel.Result): Boolean {
        if (!MeowAccessibilityService.isEnabled(activity)) {
            result.error(
                "ACCESSIBILITY_DISABLED",
                "Meow Agent Accessibility Service is not enabled. " +
                        "Please enable it in Settings → Accessibility.",
                null
            )
            return false
        }
        return true
    }
}
