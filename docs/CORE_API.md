# Saathi core contract (integration-ready)

Import `package:saathi/core/saathi_core.dart` (use the actual pubspec package name if different).
Pure Dart, `package:http` only. No persistence or Flutter widget coupling.

- `enum ProviderType { openai, anthropic, gemini, hermes, openclaw }`
- `ProviderConfig({required String id, required String name, required ProviderType type, String apiKey = '', String? baseUrl, String modelFilter = '', bool useGrounding = false})`; `toJson({bool includeSecrets = false})`, `ProviderConfig.fromJson(Map<String,dynamic>)`. IDs stable across renames. Secrets omitted by default; storage owner supplies them on reload. baseUrl is API origin/root; `/v1` and `/v1beta` roots accepted without doubling.
- `ModelInfo({required String providerId, required String name, String? displayName})`; getters `id` (`providerId|name`), `displayName`.
- `ChatMessage({required String role, required String content, String? id, Map<String,dynamic> metadata = const {}})`; internal roles `user`, `model` (also accepts `assistant`), `system`; `toJson()`, `ChatMessage.fromJson(...)`.
- `ChatResult`: `String text`, `Map<String,dynamic> metadata` (`promptTokens`/`completionTokens`/`totalTokens`, `finishReason`, Gemini `groundingMetadata`; OpenAI/Hermes preserve raw `usage`, `runtime`, `hermes` when present). No server session retention is claimed.
- `ChatChunk`: `String text` (delta), `Map<String,dynamic> metadata`; final usage can arrive in a text-empty chunk.
- `ProviderException implements Exception`: `String message`, `int? statusCode`; safe generic server errors (not raw provider bodies/keys).
- `SaathiCore({http.Client? client, int maxHistory = 20, String systemPrompt = '', Duration requestTimeout = const Duration(seconds: 60), int maxResponseBytes = 8 * 1024 * 1024})`
  - `List<ProviderConfig> get providers`, `List<ModelInfo> get models`, `List<ChatMessage> get history`, `ModelInfo? get currentModel`, `String get systemPrompt`, `bool get isBusy`.
  - `void addProvider(ProviderConfig config)`, `void removeProvider(String id)`, `void selectModel(String compoundId)`.
  - `Future<List<ModelInfo>> discoverModels(String providerId)` refreshes only that instance. `void registerModel(ModelInfo model)` supports manually specified model names when discovery is unavailable.
  - `void setSystemPrompt(String prompt)` resets local conversation; `void clearHistory()`; `void restoreHistory(List<ChatMessage> messages)`; `void setMaxHistory(int max)` (positive).
  - `Future<ChatResult> sendMessage(String text)` appends user and final model exactly once after success; errors do not mutate history. Honors system prompt and history limit. Hermes direct chat is an app-owned full-history request, not shared-session attachment.
  - `Future<ChatResult> sendRaw(List<ChatMessage> messages, {String? modelId})` no history side effects; explicit system messages override instance-wide system prompt.
  - `Stream<ChatChunk> streamMessage(String text)` OpenAI-compatible SSE initially; other providers reject explicitly (no fake streaming). Successful completed streams append final exchange; canceled/error streams do not append.
  - `void close()` closes only an internally owned client.

HTTP client is injectable. No actual credentials/prompts are used in tests. Hermes model discovery now requires `features.model_options == true` plus the canonical GET `/api/model/options` endpoint advertised by `/v1/capabilities`; it requests `include_unconfigured=false` and never treats `/v1/models` routing aliases as model inventory. `ModelInfo.upstreamProvider` is the Hermes runtime provider slug, distinct from `providerId` (the original configured connection); its compound ID distinguishes identical model names on different providers. New conversations persist that tuple and send both `provider` and `model` on Runs and compatibility Chat Completions. Compatibility requests require the explicit provider because bare model IDs can be ignored when `direct_model_requests` is disabled. Catalog reads never write server configuration or start inference. Unsupported/denied catalogs are actionable failures; an empty catalog does not invent a default. API-server bearer credentials go only to the configured original server, never catalog-provided upstream URLs.

This is selection for **new app-owned API-server conversations**, not existing native-session model mutation. Installed source precedence is confirmed Browser lock > session `/model` override > persisted session model > routing alias > request tuple > global default. A later server-side session override can therefore win; per-request selection does not mutate that override. Primary contract rechecked November 16, 2026: official API-server docs (`https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server`) and installed `/opt/hermes/gateway/platforms/api_server.py` (`_request_agent_overrides`, `_handle_model_options`, `_select_agent_runtime`), plus `hermes_cli/inventory.py`. Controlled tests are not deployed-server or device verification.

Hermes uses the official API server `/v1/chat/completions` (new app-owned conversations only), `/v1/capabilities`, `/api/sessions`, `/api/sessions/{id}/messages`. It does NOT send to foreign desktop/CLI sessions over REST. Native session list/history APIs are documented below; attaching/controlling existing open sessions requires the gateway WebSocket `prompt.submit` and is reserved for the gateway child. OpenClaw direct requests explicitly reject until its native gateway protocol is implemented by that child; source JS `/v1/agents` and naive `session_id` were not validated and are NOT implemented. Smart context bucket negotiation is deferred; bounded linear context is implemented. No current pricing estimates are invented.

## Security and lifecycle

Base URLs must use HTTPS, except explicit development loopback `http://localhost`, `http://127.0.0.1`, `http://[::1]`. URL userinfo, query and fragments are rejected at provider registration; profile path prefixes are supported. Redirects are not followed. JSON requests have an overall deadline; streams have header and idle-read deadlines. Both are size-bounded and aborted on timeout, cancellation or error. Errors omit raw bodies, prompts, keys and transport diagnostics. No automatic retries.

While a conversation request/stream is active, reconfiguration, removal and model selection throw `StateError`. `clearHistory`/system-prompt resets invalidate pending history commits. Replacing a provider ID with a different endpoint, credential or provider type clears local history and that instance's model inventory; cosmetic rename retains both. Keys are never serialized unless explicitly requested.

## Native Hermes read-only sessions (gateway child owns live attach)

Additional `SaathiCore` methods:
- `Future<Map<String,dynamic>> discoverCapabilities(String providerId)` preserves machine-readable capability flags.
- `Future<RemoteSessionPage> listRemoteSessions(String providerId, {int limit = 50, int offset = 0, String? source, bool includeChildren = false})`.
- `Future<RemoteHistoryPage> loadRemoteHistory(String providerId, String sessionId, {int limit = 100, int offset = 0, bool includeCompacted = false})`. Oldest-first explicit pagination, no local history mutation. All rows retained (including tool rows) as raw JSON, not silently flattened.
- `RemoteSession`: `String id`, `String title` (fallback to id), `String? source`, `String? model`, `bool get canContinueViaRest` (always false for this read-only integration), `Map<String,dynamic> data`.
- `RemoteSessionPage`: `List<RemoteSession> sessions`, `bool hasMore`, `int limit`, `int offset`.
- `RemoteHistoryPage`: `String sessionId` (server-resolved), `List<Map<String,dynamic>> messages`, `Map<String,dynamic> pagination` (no fabricated total/has_more).

REST history is inspect-only. UI must not restore remote history into direct chat and label it live attachment. No sending/creating sessions in these APIs. Independent native gateway child can import core models but should put its implementation in its separately assigned path (do not edit core paths).

Implementation/coverage details tracked in PORT_AUDIT.md. Contract additions will be backward compatible.
