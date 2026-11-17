# Design decisions: Sathi → Saathi

Saathi is an independent Flutter app, not a QML port or DMS frontend. The original DMS repository was only read; it has not been changed.

| Decision | Keep/build on | Change or leave behind |
|---|---|---|
| Identity | A familiar personal companion | Saathi spelling, independent launcher/package, no Hermes-only identity |
| Navigation | Conversation first, provider choice nearby | Mobile routes and a secondary conversation drawer instead of a shell panel |
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
| Desktop future | Shared Dart network/state/storage code, existing Linux/macOS runners | Leave DMS pinning, shell shortcuts, resizing/theme bindings and plugin service APIs behind |

## Deliberately not carried over yet
- Smart context bucket negotiation/fast-model summarization. It adds complexity and potentially paid extra calls; it must be opt-in and should not run on top of a server-owned session.
- Hardcoded historical token prices. Raw usage can be preserved by the core, but cost estimates need maintained pricing rather than false precision.
- Native OpenClaw gateway pairing and session control. The old adapter's guessed endpoints are not a verified integration.
- Direct-model UI streaming; native Runs and canonical visible-text streaming are integrated with authoritative reconciliation.
- Attachments/share-sheet intake and production desktop installation/tray behavior. Conversation organization/personas, visibility-based unread and reported usage are integrated; native persona mutation remains unsupported.

See [Hermes acceptance evidence](HERMES_DELIVERY_ACCEPTANCE.md) for controlled fixture and official-backend probe boundaries. Integrated source is not proof of a deployed host, native secure storage or device acceptance.

## Prompt optimization entry
Hold Send to open a compact **Optimize prompt** menu; releasing or dismissing it never sends or changes the draft. Shift+F10, the context-menu key, secondary click and Send's accessible long-press/custom action open the same menu. There is no separate default optimizer icon. The optimizer stays mounted across keyboard changes and owns preview, explicit Apply/Keep original and Undo. Global and per-chat destinations are separate from the response model. Only bounded direct-text rewrites are eligible; native work, including approval-waiting Runs, disables optimization without turning a hold into a queued tap. See [the optimizer contract](PROMPT_OPTIMIZER.md).

## Layout verification
The composer stays outside the scrolling transcript and queue/recovery feedback, at the bottom safe area (above the keyboard when open). The transcript fills the space left by the composer and native-run controls; short feedback uses only its content height, while long feedback scrolls within a bounded share of that remaining space. Agent activity stays directly above the input.

`test/ui/pinned_composer_test.dart` covers empty, short and long history at 360px/390px, 2× text, multiline drafts, bottom safe-area padding and keyboard open/closed. Queue recovery and the joint pending-approval/live-child-activity tests also exercise reachable controls without sending another inference request.

Widget tests exercise 390×844 and 360px with 2× text and keyboard insets. `docs/previews/saathi-*.png` are Flutter test renders, not physical Android screenshots. The populated conversation previews contain explicitly synthetic display fixtures; no provider was contacted to create them. The older `chat.png`/`activity.png` files are historical Iris demo renders.
