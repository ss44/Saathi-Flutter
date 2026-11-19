# Design decisions: Sathi → Saathi

Saathi is an independent Flutter app, not a QML port or DMS frontend. The original DMS repository was only read; it has not been changed.

| Decision | Keep/build on | Change or leave behind |
|---|---|---|
| Identity | A familiar personal companion | Saathi spelling, independent launcher/package, no Hermes-only identity |
| Navigation | Conversation first, provider choice nearby | Narrow windows use mobile routes and a conversation drawer; wide windows use a far-left Chats/Settings rail, persistent chat list and active conversation pane |
| Providers | Multiple named instances; OpenAI-compatible, Anthropic, Gemini; model discovery/manual IDs | Separate Dart adapters; no QML global state or false claim that all backends expose the same capabilities |
| Context | System prompt and bounded direct-model context | Conversation keeps its original connection; direct reply model/instructions change only after explicit per-chat Save, never by rerouting history |
| Local sessions | Persistent conversations, new/delete/switch | Connection-bound sessions rather than one shared global history; credentials never stored in session JSON |
| Remote sessions | Continue API-owned Hermes sessions or explicitly attach Desktop/CLI sessions with a trusted host invitation, sending only new input | Native attachment requires operator-provided reachable WSS and fresh grants; never transplant foreign history through REST |
| Chat display | Readable messages, markdown, minimal chrome | Empty genuine startup instead of a permanent demo transcript |
| Activity | Observable status while running; inspect after completion | Swipe a completed response to show/hide status; never expose private hidden reasoning or invent tool output |
| Copy | Easy access to the original markdown text | Long-press copies immediately and confirms with a snackbar. Markdown selection is off on this touch surface so it cannot steal swipe/long-press gestures |
| Secrets | User-supplied connection credentials | Platform secure storage; no plain-preference keys, debug logging or screenshots of credentials |
| Errors | Recoverable settings/network messages | Successful replies are retained if saving fails; retry saving without another model request |
| Updates | Automatic checks and clear update availability | Verified standalone Android APK download + OS consent. Desktop currently opens releases manually; publication does not prove device installation or upgrade acceptance |
| Desktop workspace | Shared Dart network/state/storage code and adaptive Flutter shell, Linux-first native preview | Keep settings in the left navigation and cap the conversation content width; leave DMS pinning, shell shortcuts, resizing/theme bindings and plugin service APIs behind |

## Deliberately not carried over yet
- Smart context bucket negotiation/fast-model summarization. It adds complexity and potentially paid extra calls; it must be opt-in and should not run on top of a server-owned session.
- Hardcoded historical token prices. Raw usage can be preserved by the core, but cost estimates need maintained pricing rather than false precision.
- Native OpenClaw gateway pairing and session control. The old adapter's guessed endpoints are not a verified integration.
- Direct-model UI streaming; native Runs and canonical visible-text streaming are integrated with authoritative reconciliation.
- Attachments/share-sheet intake and production desktop installation/tray behavior. Conversation organization/personas, visibility-based unread and reported usage are integrated; native persona mutation remains unsupported.

See [Hermes acceptance evidence](HERMES_DELIVERY_ACCEPTANCE.md) for controlled fixture and official-backend probe boundaries. Integrated source is not proof of a deployed host, native secure storage or device acceptance.

## Prompt optimization entry

Holding Send expands its control upward into a compact, anchored vertical group:
Enhance prompt above Close send actions (in Send's original position). Both icon
buttons have 48px touch targets and accessible tooltips; the default composer
has no always-visible optimizer. A fresh action tap is required: releasing or
sliding the opening hold cannot select an action or send. Outside tap, Back,
Escape and Close dismiss without changing the draft. Ordinary Send taps remain
unchanged. Shift+F10, the context-menu key, secondary click and Send's custom
screen-reader action open the same group; Enter/Space and Tab operate its buttons.
Removing the Send owner also removes its modal surface.

Enhance reuses the existing explicit review request, Original/Improved preview,
Apply, Keep original and revision/source-bound Undo; it never sends automatically.
The optimizer stays mounted across keyboard changes. Global and per-chat rewrite
destinations remain separate from the response model. Only bounded direct-text
rewrites are eligible; native work, including approval-waiting Runs, disables
optimization without turning a hold into a queued tap. See [the optimizer
contract](PROMPT_OPTIMIZER.md).
`test/send_action_group_test.dart` verifies the real ChatHome at 360px/390px,
2× text, keyboard open/closed and long drafts, including hold movement, dismissal,
keyboard activation and semantics actions. Existing optimizer tests retain the
source/lifecycle revocation and Apply/Keep/Undo coverage. These are widget tests,
not physical-device or TalkBack verification.

## Unified settings

Compact navigation has one accessible **Settings** action, not a separate
chat-optimizer settings icon. Wide navigation keeps the existing **Settings** rail
destination and embedded pane, without adding a toolbar shortcut. Its scrollable pane groups **Connections**,
**Application** (global optimizer, notifications and app updates), and **Current
conversation** (optimizer override/inheritance). Detail screens and dialogs return
to that pane; Back returns to the untouched composer draft, including from the
embedded desktop pane. The conversation section captures the chat on deliberate
Settings entry, not when the desktop shell mounts its inactive panes. On compact
navigation it is hidden if selection changes; desktop selection returns to chat
and the next Settings entry captures that chat. Choosing optimizer settings never changes the response model,
connection or instructions. Connection edit/save/delete retains its existing secure
storage and validation paths. Update checks and installation consent are unchanged;
there is no new automatic-update preference.

Settings rows use the current theme. Appearance/System/Light/Dark implementation
is tracked separately in #63; this consolidation adds no toolbar theme toggle or
placeholder preference.

All finite settings rows remain mounted for keyboard traversal and focus-driven
scrolling. Regression tests cover Tab/Enter/Escape, 360px/2x text with keyboard
insets, real connection edit/save/delete, notifications, updates, desktop rail
navigation/Back, captured chat scope and active conversation isolation. Optimizer
save failures restore the prior raw preference in the plugin cache and storage;
false and throwing channel writes are tested with same-cache and cold owners.
These are controlled widget/storage tests, not native-device accessibility or
OS-storage durability certification.

## Transcript presentation

Historical rows are filtered only at the presentation boundary: blank/whitespace assistant messages and raw tool records occupy no bubble or spacing. Original local records, canonical row identities and remote pagination counts remain unchanged. Gateway-sanitized tool labels are available by swiping the following response; raw tool bodies are never substituted for answers. Active thinking/streaming and terminal-error recovery remain separate from historical filtering.

Both speakers use theme-derived bubbles (user right, assistant left). The UI does not prepend an assistant name or rewrite response content. Markdown, blocked-image placeholders, immediate long-press copy and swipe activity share one renderer for local and remote history. Supported structured remote text is projected before filtering; image-only blocks retain a blocked attachment placeholder without fetching or storing their URLs, including canonical snapshot and paged-transcript paths. This does not add attachment downloads or previews.

A newly settled empty answer remains an explicit conversation-owned outcome, not a successful reply bubble or completion notification. Direct, native Runs and canonical storage retries cannot erase that outcome or resend inference; canonical emptiness is established only from the settled original input and typed answer rows. Imported historical blanks do not create errors. The outcome is retained for the current controller lifetime; historical blanks alone are not reclassified as failed work after restart.

`test/ui/transcript_presentation_test.dart` covers mixed history, raw pagination, safe image-only placeholders, exact Markdown copy, real swipe gestures and 360px/390px 2× text in both brightness modes. The independent outcome, native-image and Runs-outcome tests cover snapshot/journal storage failure and retry, no duplicate submission, typed activity and completion accounting. Existing adaptive-workspace, streaming scroll-ownership and native combined-home regressions remain separate gates.

## Desktop conversation settings

On Linux, macOS and Windows in the wide workspace, **Chat settings** opens a
right-hand panel beside the current transcript. The conversation list stays
mounted but is temporarily hidden to leave room for the conversation. Application
Settings remains in the left rail; Enhance retains its separate destination.
Compact windows and mobile platforms keep their existing navigation; #73's mobile
interaction remains unspecified.

For direct OpenAI-compatible, Anthropic and Gemini chats, Save commits a manual
reply-model ID, a reusable persona selection and chat-specific instructions in one
metadata write. Selecting a shared persona uses its instructions without editing
that shared role; selecting **This chat’s instructions** enables chat-only text.
Changes apply only to future inputs on the original connection. Accepted, queued,
uncertain and unsaved work blocks edits, and each accepted direct input captures
its effective model and instructions for persistence/recovery. Cancel never saves.

Native conversations are read-only in this panel: saved model/instruction values
are not asserted to be the current server configuration. The shipped adapters
have no verified existing-session model/persona/system-instruction mutation
contract. No global server configuration is changed, history replayed, session
replaced or inference started by opening or saving settings. Native mutation and
deployed-server/device acceptance remain separate work.

## Layout verification
Wide windows at least 1,000 logical pixels use the persistent workspace when there is also room for the current text scale (at least 720 times the scaled unit size). The chat list stays 300px wide beside the navigation rail; conversation content is capped at 960px. Settings opens inside the workspace without replacing the conversation or its draft. Resizing back to compact navigation preserves the composer. Selecting an API-owned remote conversation now checks its native Runs support and opens the original-session composer automatically, retaining visible history while connecting. Desktop/CLI sessions still require their own authenticated gateway authority, not a replay through REST; unavailable permission, protocol and reconnect states explain the prerequisite. See [existing-conversation participation](EXISTING_CONVERSATIONS.md).

`test/ui/desktop_shell_test.dart` exercises desktop and landscape layouts, conversation selection/draft ownership, embedded settings, resizing and large-text fallback. Native compilation and interactive Linux, Windows and macOS acceptance are separate from these widget tests.

The composer stays outside the scrolling transcript and queue/recovery feedback, at the bottom safe area (above the keyboard when open). The transcript fills the space left by the composer and native-run controls; short feedback uses only its content height, while long feedback scrolls within a bounded share of that remaining space. Agent activity stays directly above the input.

`test/ui/pinned_composer_test.dart` covers empty, short and long history at 360px/390px, 2× text, multiline drafts, bottom safe-area padding and keyboard open/closed. Queue recovery and the joint pending-approval/live-child-activity tests also exercise reachable controls without sending another inference request.

Widget tests exercise 390×844 and 360px with 2× text and keyboard insets. `docs/previews/saathi-*.png` are Flutter test renders, not physical Android screenshots. The populated conversation previews contain explicitly synthetic display fixtures; no provider was contacted to create them. The older `chat.png`/`activity.png` files are historical Iris demo renders.
