# Design decisions: Sathi → Saathi

Saathi is an independent Flutter app, not a QML port or DMS frontend. The original DMS repository was only read; it has not been changed.

| Decision | Keep/build on | Change or leave behind |
|---|---|---|
| Identity | A familiar personal companion | Saathi spelling, independent launcher/package, no Hermes-only identity |
| Navigation | Conversation first, provider choice nearby | Mobile routes and a secondary conversation drawer instead of a shell panel |
| Providers | Multiple named instances; OpenAI-compatible, Anthropic, Gemini; model discovery/manual IDs | Separate Dart adapters; no QML global state or false claim that all backends expose the same capabilities |
| Context | System prompt and bounded direct-model context | Conversation keeps its original connection/model/prompt; no silent rerouting of a transcript |
| Local sessions | Persistent conversations, new/delete/switch | Connection-bound sessions rather than one shared global history; credentials never stored in session JSON |
| Remote sessions | Native backend can retain authoritative history and accept only new input | Read-only REST browsing is labeled read-only; live attach is a separate gateway path, not imported history |
| Chat display | Readable messages, markdown, minimal chrome | Empty genuine startup instead of a permanent demo transcript |
| Activity | Observable status while running; inspect after completion | Swipe a completed response to show/hide status; never expose private hidden reasoning or invent tool output |
| Copy | Easy access to the original markdown text | Long-press copies immediately and confirms with a snackbar. Markdown selection is off on this touch surface so it cannot steal swipe/long-press gestures |
| Secrets | User-supplied connection credentials | Platform secure storage; no plain-preference keys, debug logging or screenshots of credentials |
| Errors | Recoverable settings/network messages | Successful replies are retained if saving fails; retry saving without another model request |
| Updates | Automatic checks and clear update availability | Verified standalone Android APK download + OS consent. Desktop currently opens releases manually; repo/signing/device verification are still needed |
| Desktop future | Shared Dart network/state/storage code, existing Linux/macOS runners | Leave DMS pinning, shell shortcuts, resizing/theme bindings and plugin service APIs behind |

## Deliberately not carried over yet
- Smart context bucket negotiation/fast-model summarization. It adds complexity and potentially paid extra calls; it must be opt-in and should not run on top of a server-owned session.
- Hardcoded historical token prices. Raw usage can be preserved by the core, but cost estimates need maintained pricing rather than false precision.
- Native OpenClaw gateway pairing and session control. The old adapter's guessed endpoints are not a verified integration.
- Streaming in the UI (the core has tested OpenAI/Hermes SSE support); cancellation/reconnect UX needs a dedicated end-to-end pass.
- Connection editing/removal (the first UI supports adding connections), attachments/share-sheet intake, and production desktop installation/tray behavior.

## Layout verification
Widget tests exercise 390×844 and 360px with 2× text and keyboard insets. `docs/previews/saathi-*.png` are Flutter test renders, not physical Android screenshots. The populated conversation previews contain explicitly synthetic display fixtures; no provider was contacted to create them. The older `chat.png`/`activity.png` files are historical Iris demo renders.
