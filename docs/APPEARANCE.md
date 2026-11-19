# Appearance

Saathi follows the operating system's light/dark preference by default, including
changes while open. The existing Settings destination contains System, Light and
Dark choices in the unified Application section; there is no new toolbar toggle
or route. Light and Dark override OS
changes until the person returns to System.

## Ownership and storage

`SaathiApp` owns one `Appearance` notifier alongside its chat controller and stable
Navigator key. `MaterialApp.themeMode` observes the committed choice. Changing
appearance rebuilds presentation without replacing the chat controller, selected
conversation, draft controller, focus, transcript scroll or active request.

The app-only `saathi.appearance.v1` preference stores `system`, `light` or `dark`.
Missing/invalid values use System without rewriting the original raw value.
The controlled selector and active theme change only after a successful write;
the selector is disabled during persistence. It does not show an optimistic
candidate as saved. Accepted writes may settle after disposal without notifying
a disposed owner; new mutations from that owner are rejected.

Legacy SharedPreferences changes its Dart cache before platform acknowledgement.
On false returns or thrown writes, appearance restores the exact committed raw
value or absence. Owners sharing one preferences cache share that committed value
and recovery error, never initializing from an in-flight optimistic write.
Accepted writes continue across owner replacement. The latest successfully
acknowledged selection in acceptance order wins; a newer failed selection does
not discard an older accepted success. Settlement and compensation are ordered,
and overlapping writes reassert the latest committed value so an old completion
cannot overwrite a replacement's successful choice. If compensation is not
acknowledged, all live/replacement owners retain the committed choice and warn
that restarting could produce a different choice.
Selecting that same choice again retries storage. This coordination is limited
to one preferences cache in one isolate; it cannot guarantee native disk atomicity
or correct a failed platform write across process death.

## Palette

The existing light brand palette is retained; the dark Material 3 palette uses the
same seed. Chat/composer, historical user and assistant bubbles, secondary text,
dividers and
the adaptive desktop rail/sidebar use paired semantic ColorScheme roles.
Local/wrapped replies and remote history share themed Markdown link, task-state
icon, code text and code-block colors, without changing image-blocking or
interaction policy. Checked and unchecked task icons use ColorScheme.primary
rather than the dependency's legacy primaryColor and are tested against the
actual rendered bubble in both palettes.
Existing thinking/activity, Send/Enhance, dialogs, connection forms, settings and
update surfaces continue to inherit Material themes and interactive states.

## Verification boundaries

Appearance widget tests cover default/invalid settings, live OS changes, overrides,
return to System and cold preferences reload; controlled platform-channel tests
separate Dart cache from backing storage for false/throwing writes, mutation before
failure, compensation failure and retry. They also cover pending selector state,
owner disposal, same-cache owner recreation and durable-store reconstruction.

Real routes/controls are exercised with 360/390px, 2x text, keyboard insets,
Tab/Enter access and selector semantics. Focused draft/selection/scroll identities,
an admitted controlled request, a captured explicitly paused follower and a newer
draft survive theme changes. Wide workspace tests exercise its rail, sidebar and
embedded settings, preserving the original chat and draft across navigation.
Representative text/background contrast pairs meet 4.5:1 in both palettes.

These are Flutter widget and controlled-channel results, not physical Android,
Linux/macOS/Windows OS brightness-delivery, native preference durability, real
IME, screen-reader, screenshot or device acceptance. A joint actual-Settings test
checks both bubble palettes, canonical history preservation, draft/focus/reader
identity and zero requests. Full-suite coverage, independent review and replay on
the corrected unified-settings/bubble seed remain parent-owned final gates.
