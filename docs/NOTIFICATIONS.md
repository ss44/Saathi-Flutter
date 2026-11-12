# Background reply notifications

Android-only local notifications, off by default. Enable explicitly from **Connections → Notifications**. Only the `saathi.notifications.enabled.v1` boolean is stored in ordinary preferences; permission is requested only when enabling. Android app/channel denial remains authoritative. Other platforms show an unsupported explanation without requesting native permissions.

A successful `ChatController.send` appends its actual response to the captured conversation, then emits one completion callback independently of persistence. Retrying storage never emits another completion or resends a request. Notification failures cannot turn a received response into a failed send. Dart permits only paused/hidden lifecycle states; native posting also requires a stopped Activity. Inactive permission dialogs, foreground and initial detached states do not qualify. Returning to foreground before native handling suppresses posting.

The framework-only `saathi/notifications` bridge uses a stable Android 26+ channel and Android 33+ POST_NOTIFICATIONS consent. Notifications contain only **A reply is ready in Saathi.**, never response text or credentials. A private visibility notification and monochrome small icon are used. Conversation ID is the notification tag; the explicit immutable PendingIntent has a validated opaque-ID URI identity, not a hash-derived request code.

Warm intents are queued natively and signal Dart; cold intents remain queued until controller loading completes. `consumePendingTap` drains once, validates IDs again, selects only a uniquely matching existing local conversation, and returns navigation to the root chat. Unknown, malformed or foreign IDs do nothing. Taps never create sessions, fetch remote history or send messages. Observers, callbacks and native handlers are disposed with their owners.

## Limits / device acceptance

This is not push messaging, an Android background service, a remote job feed or gateway attachment. A response must reach the running app. Killed apps and Doze/network restrictions can prevent delivery; independent server jobs require a future gateway/push design. No automatic send retry or replay was added.

Focused Flutter tests exercise lifecycle filtering, default-off and permission denial, adapter failure isolation, completion ownership after selection changes, storage failure without resend, tap validation/draining and existing-only session selection. Native compilation/device behavior is **not** established by these tests. Validate Android 26/32/33+, denial/channel blocking, rapid resume before channel handling, permission dialog, cold/warm taps, lock screen privacy and repeated replies on devices before release. No package/build dependency or installer/signature logic changes are required.
