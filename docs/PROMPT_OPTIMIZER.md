# Prompt optimizer

The composer has no separate enhance button. Hold Send, use its screen-reader
Enhance prompt action, press the context-menu key / Shift+F10 while Send has
focus, or secondary-click Send. Send expands upward into an anchored vertical
icon-button group: **Enhance prompt** above **Close send actions**, which replaces
Send in the group. Both targets are 48px. A normal Send tap still sends normally;
releasing/sliding a hold or dismissing the group does not send or alter the draft.
A fresh Enhance activation opens review. Outside tap, Close, Back and Escape
only dismiss; keyboard focus starts at Enhance and Tab reaches Close.

Open **Settings** from compact navigation or the desktop rail. Under **Application**, set
**Global prompt optimizer**. Under **Current conversation**, **Chat prompt
optimizer** chooses a chat override or **Inherit global setting**.
Settings are separate from the response model and resolve override → global.
There is no implicit response-model default or automatic replacement.

The picker groups models beneath each named connection and fetches that source's
current catalog. Native Hermes and OpenClaw connections stay visible with a
bounded-rewrite-unavailable explanation; they are not called as agents, given
tools, or silently replaced. This implementation intentionally adds no Hermes
one-shot endpoint or global server configuration mutation.

Before Improve, review the connection, URL and exact model in Destination. Only
the draft and rewrite instruction are sent in one additional text request;
conversation history and its system instructions are excluded. Provider charges
may apply. Drafts and accepted rewrites are limited to 16,000 characters; the
existing transport's timeout/response-size bounds also apply. Apply replaces only
the unchanged original draft. Keep original/cancel preserve it. Undo restores
only that application, not a subsequently edited draft or another conversation.
None of these actions sends a conversation message.

## Integration contract

`lib/ui/optimizer_settings.dart` provides:

- `OptimizerSelection(connectionId:, model:, provider:)`: exact tuple identity;
  its JSON encoder/decoder whitelist only these safe strings.
- `OptimizerSettings` extension on `ChatController`:
  `globalOptimizerSelection`, `optimizerOverride(chat)`,
  `optimizerSelection(chat)`, `saveOptimizerSelection(selection, {chat})`,
  `optimizerRevision`, and `optimizerSettingsSaving`.
- `OptimizerSettingsButton(controller:, chat:)`: omit chat for global settings;
  pass the captured chat for override/inherit settings.

The extension owns no response-model, chat-history or transport mutations. It
persists a separate `saathi.optimizer.v1` preferences document containing a global
tuple and chat-ID-to-tuple overrides. Runtime values change only after successful
storage. Failed writes compensate the exact previous raw preference (including
absence), because the plugin can mutate its cache before storage acknowledges a
write. Compensation failures remain errors, not successful saves. Save attempts
and completion replace an opaque authority revision.

`PromptOptimizer(controller:, composer:, triggerBuilder:)` retains review/Undo
ownership while ChatHome supplies the Send/menu trigger. Its default trigger is
kept only for isolated embedding/tests, not the app composer. `PromptReview`
returns an authority-bound `OptimizerPreview`, not an unguarded replacement
string. Composer revision, session, connection-map identity, setting revision,
lifecycle generation, and owner mounting revoke asynchronous work. A revoked
source/selection cannot become valid by changing away and back. Catalog/result
loading ownership is separate from result authority; a fresh picker can recover.

The unified Settings route presents the global picker under Application and a
captured current-chat picker under Current conversation. The same dialog and
persistence contract serves both; `asTile` supplies the settings-row presentation.
No controller, store, or core file changes are required. History serialization
remains unchanged.

## Verification boundaries

Widget tests exercise 360/390px layouts, 2x text and keyboard insets, release and
dismiss gestures, ordinary Send, keyboard/semantics exposure, grouped override /
inheritance, preview/Apply/Keep/Undo, and delayed-secret/catalog/HTTP revocation.
A real localhost HTTP fixture verifies `/v1/models` and exactly one draft-only
`/v1/chat/completions` POST. Mock protocol fixtures separately retain all three
direct providers' history/tool privacy assertions. These are not production,
Android-device, screen-reader-device, native-build, or paid-inference evidence.
