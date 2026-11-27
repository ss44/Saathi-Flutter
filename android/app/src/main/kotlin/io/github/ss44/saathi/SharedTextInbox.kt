package io.github.ss44.saathi

import android.content.Intent
import io.flutter.plugin.common.MethodChannel
import java.util.ArrayDeque

/** Holds bounded, unconsumed shares in memory until the chat screen is ready. */
internal class SharedTextInbox(private val channel: MethodChannel) {
    private val pending = ArrayDeque<String>()

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "takePendingText" -> result.success(pending.pollFirst())
                else -> result.notImplemented()
            }
        }
    }

    fun accept(intent: Intent): Boolean {
        if (intent.action != Intent.ACTION_SEND || intent.type != "text/plain") return false
        // Explicit intents can bypass manifest filtering and contain malformed extras.
        val text = try {
            intent.getCharSequenceExtra(Intent.EXTRA_TEXT)
        } catch (_: RuntimeException) {
            null
        } ?: return false
        // Match ChatController.maxInputLength in UTF-16 code units.
        if (text.length > 256 * 1024 || text.isBlank() || pending.size >= 8) return false
        pending.addLast(text.toString())
        channel.invokeMethod("sharedTextAvailable", null)
        return true
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        pending.clear()
    }
}
