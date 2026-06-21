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
 * Handles: contact resolution, phone calls, and SMS.
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
                "makeCall" -> makeCall(call, result)
                "sendSms" -> sendSms(call, result)
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
}
