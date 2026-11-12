package io.github.ss44.saathi

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import io.flutter.plugin.common.MethodChannel
import java.util.ArrayDeque

/** Local completions only; no worker, remote feed, or network retry. */
class ReplyNotifications(private val activity: MainActivity, private val channel: MethodChannel) {
    private val manager = activity.getSystemService(NotificationManager::class.java)
    private val taps = ArrayDeque<String>()
    private var permission: MethodChannel.Result? = null
    var background = false
    private val channelId = "background_replies"
    private val action = "io.github.ss44.saathi.REPLY"
    init {
        if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(
            NotificationChannel(channelId, "Background replies", NotificationManager.IMPORTANCE_DEFAULT))
        accept(activity.intent)
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "requestPermission" -> {
                        if (Build.VERSION.SDK_INT >= 33 && activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                            if (permission != null) result.success(false)
                            else {
                                permission = result
                                activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 731)
                            }
                        } else result.success(allowed())
                    }
                    "show" -> { call.argument<String>("id")?.let { show(it) }; result.success(null) }
                    "consumePendingTap" -> result.success(consumePendingTap())
                    else -> result.notImplemented()
                }
            } catch (_: Exception) { result.error("notifications_unavailable", "Notifications unavailable", null) }
        }
    }
    private fun valid(id: String) = id.matches(Regex("^[A-Za-z0-9_-]{1,128}$"))
    private fun allowed(): Boolean {
        if (Build.VERSION.SDK_INT >= 33 && activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return false
        if (Build.VERSION.SDK_INT >= 24 && !manager.areNotificationsEnabled()) return false
        return Build.VERSION.SDK_INT < 26 || manager.getNotificationChannel(channelId)?.importance != NotificationManager.IMPORTANCE_NONE
    }
    fun permissionResult() { permission?.success(allowed()); permission = null }
    private fun conversationId(intent: Intent?): String? {
        if (intent?.action != action) return null
        val uri = intent.data ?: return null
        val id = uri.pathSegments.singleOrNull() ?: return null
        if (uri.scheme != "saathi-reply" || uri.host != "conversation" || uri.query != null || uri.fragment != null || !valid(id) || uri.encodedPath != "/$id") return null
        return id
    }
    fun accept(intent: Intent?) {
        val id = conversationId(intent) ?: return
        if (!taps.contains(id)) {
            if (taps.size >= 32) taps.removeFirst()
            taps.addLast(id)
        }
        channel.invokeMethod("pendingTap", null)
        // Keep the latest intent pending until Dart is ready, including recreation.
    }
    private fun consumePendingTap(): String? {
        val id = taps.pollFirst() ?: return null
        if (conversationId(activity.intent) == id) {
            activity.intent?.apply { action = Intent.ACTION_MAIN; data = null }
        }
        return id
    }
    private fun show(id: String) {
        if (!background || !valid(id) || !allowed()) return
        val intent = Intent(activity, MainActivity::class.java).apply {
            action = this@ReplyNotifications.action
            data = Uri.Builder().scheme("saathi-reply").authority("conversation").appendPath(id).build()
            flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pending = PendingIntent.getActivity(activity, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(activity, channelId) else Notification.Builder(activity)
        manager.notify(id, 1, builder.setSmallIcon(R.drawable.ic_reply_notification)
            .setContentTitle("Saathi").setContentText("A reply is ready in Saathi.")
            .setVisibility(Notification.VISIBILITY_PRIVATE).setAutoCancel(true)
            .setContentIntent(pending).build())
    }
    fun dispose() {
        permission?.success(false)
        permission = null
        channel.setMethodCallHandler(null)
    }
}
