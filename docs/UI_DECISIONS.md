# Design decisions: Sathi → Saathi

Saathi is an independent Flutter app, not a QML port or DMS frontend. The original DMS repository was only read; it has not been changed.

| Decision | Keep/build on | Change or leave behind |
|---|---|---|
| Identity | A familiar personal companion | Saathi spelling, independent launcher/package, no Hermes-only identity |
| Navigation | Conversation first, provider choice nearby | Narrow windows use mobile routes and a conversation drawer; wide windows use a far-left Chats/Settings rail, persistent chat list and active conversation pane |
| Providers | Multiple named instances; OpenAI-compatible, Anthropic, Gemini; model discovery/manual IDs | Separate Dart adapters; no QML global state or false claim that all backends expose the same capabilities |
| Context | System prompt and bounded direct-model context | Conversation keeps its original connection/model/prompt; no silent rerouting of a transcript |
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

## Layout verification
Wide windows at least 1,000 logical pixels use the persistent workspace when there is also room for the current text scale (at least 720 times the scaled unit size). The chat list stays 300px wide beside the navigation rail; conversation content is capped at 960px. Settings opens inside the workspace without replacing the conversation or its draft. Resizing back to compact navigation preserves the composer. Remote history continues to open as a separate read-only route, not as a local conversation or replayed input.

`test/ui/desktop_shell_test.dart` exercises desktop and landscape layouts, conversation selection/draft ownership, embedded settings, resizing and large-text fallback. Native compilation and interactive Linux, Windows and macOS acceptance are separate from these widget tests.

The composer stays outside the scrolling transcript and queue/recovery feedback, at the bottom safe area (above the keyboard when open). The transcript fills the space left by the composer and native-run controls; short feedback uses only its content height, while long feedback scrolls within a bounded share of that remaining space. Agent activity stays directly above the input.

`test/ui/pinned_composer_test.dart` covers empty, short and long history at 360px/390px, 2× text, multiline drafts, bottom safe-area padding and keyboard open/closed. Queue recovery and the joint pending-approval/live-child-activity tests also exercise reachable controls without sending another inference request.

Widget tests exercise 390×844 and 360px with 2× text and keyboard insets. `docs/previews/saathi-*.png` are Flutter test renders, not physical Android screenshots. The populated conversation previews contain explicitly synthetic display fixtures; no provider was contacted to create them. The older `chat.png`/`activity.png` files are historical Iris demo renders.
