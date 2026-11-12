# Hermes dashboard cookie authentication

`lib/auth/hermes_dashboard_auth.dart` is a native `dart:io` broker, independent of UI, core providers and storage. This is **not HTTP Basic**, an API key, or the API server's `/v1/capabilities` flow. There is no API-key fallback.

## Public integration contract

```dart
abstract interface class DashboardSession {
  Future<DashboardIdentity> signIn(String username, String password);
  Future<DashboardIdentity> currentIdentity();
  Future<GatewayGrant> grant();
  Future<void> signOut();
  void close();
}
```

Construct `HermesDashboardAuth(baseUrl: dashboardUri, savedSession: secureJson, onSessionChanged: callback, client: optionalHttpClient)`. `DashboardIdentity` exposes `userId`, `provider`, `displayName`, optional UTC `expiresAt`. `AuthException` exposes generic `message` and optional `statusCode`, never response bodies or credentials.

The callback must await secure-storage write of non-null state and deletion for null. Never export this JSON to settings/history/logging: it contains bearer-equivalent session cookies, including the gateway sign-in binding. Password and username are submitted exactly, including whitespace, and are never persisted by the broker. `close()` disposes the client and stops new callbacks; it does not log out or delete the stored session. The broker owns even an injected client. Operations are serialized.

The Connections page body exposes **Hermes dashboard — username & password**, separately from API-server key connections. `DashboardStore` stores only `{id,name,baseUrl}` in `saathi.dashboard.connections.v1`; session JSON uses namespaced `SecretStore` IDs `dashboard.session.v1.<id>`. Saved opens validate `currentIdentity()` before connecting; every gateway connection requests a fresh ticket. Failed storage is an error, not a successful sign-in.

Signed-in identity leads to **View sessions (read-only)**, live/stored list windows (up to 50 each), and explicit `session.resume` snapshots. Text-only rendering never fetches embedded images. Refresh explicitly; this UI does not project live deltas. It sends no prompts/approvals, creates no remote sessions, and never imports remote messages into local history. Oversized/unsupported snapshots and unavailable canonical gateways are reported as errors. Browser exit disposes the gateway but retains the secure cookie; dashboard-page exit closes the broker transport. Sign out/remove attempts server logout and deletes local secure state even after network failure; storage deletion failure is reported honestly.

Cookie refresh persistence remains serialized outside the cancellable HTTP deadline; DashboardStore also serializes per-connection secure writes/deletion to avoid stale credentials resurrecting after removal. Cookie `Domain` support is intentionally narrower than a browser: only the exact dashboard hostname (with optional leading dot) is accepted. Deployments setting parent-domain cookies must configure host-only cookies for this client; foreign or parent-domain cookies are rejected rather than silently accepted.

## Protocol and security rules

1. Discover `basic` with `supports_password: true` from `GET api/auth/providers` before sending credentials.
2. POST JSON `{provider: basic, username, password, next: /}` to `auth/password-login`. Require `ok: true` and cookies, then validate `GET api/auth/me` before initially persisting.
3. Cookies come only from `HttpClientResponse.cookies`, not JSON or comma splitting. Names are opaque, including dynamic gateway suffixes and `__Host-` / `__Secure-` names. Store paths/domain/secure/HttpOnly and **absolute expiry**, converting Max-Age at receipt. Expired/deleted cookies are removed; refresh replacements from identity and ticket responses are persisted.
4. The private jar is bound to exact normalized scheme/host/port/mount URL. Foreign domains, changed origin/mount state, insecure Secure cookies and invalid cookie prefixes are rejected. Cookie paths are matched at segment boundaries. HTTPS is mandatory except literal loopback IP addresses; localhost DNS is deliberately not an HTTP exception. URL userinfo/query/fragment are rejected. TLS verification is unchanged.
5. Every request sends the dashboard's exact Origin. Installed middleware requires own-origin cookie writes on the gateway Webapp; it permits native requests without Origin only with no Fetch Metadata or `Sec-Fetch-Site: none`. With Origin and no Fetch Metadata it compares against configured public origin/Host. This broker sends no forwarded headers or spoofed Fetch Metadata. The gateway additionally checks its sign-in-binding cookie; preserving all server-issued cookies is essential.
6. POST `api/auth/ws-ticket` for each grant; require a URL-safe ticket and 30-second TTL. Return existing `GatewayGrant` with mount-preserving `wss://…/api/ws` (`ws` only for loopback HTTP) and protocols `hermes-gateway-v1`, `hermes-gateway-ticket.TICKET`. The server enforces single use; the broker never caches tickets.
7. POST `auth/logout` accepts the expected 302 without following it. Always clear local state in finally, even when the server cannot be reached. Basic provider revocation is a no-op; local deletion is essential. All other redirects are rejected before cookies/credentials can be forwarded.

Requests have 15-second deadlines (timed-out requests are aborted), 16 KiB credential-body and 64 KiB response limits. Saved JSON is bounded to 64 KiB and 64 cookies. No credentials, cookies or ticket values are logged.

## Verification and references

Tests use real ephemeral loopback HttpServer fixtures, never live configuration or credentials. Run `flutter pub get`, `flutter test --no-test-assets test/auth`, and `flutter analyze lib/auth test/auth`.

Contracts were checked against installed primary source: `hermes_cli/dashboard_auth/{routes,cookies,middleware,request_utils}.py` and `plugins/dashboard_auth/basic/__init__.py` under `/opt/hermes`. Operator documentation: `https://hermes-agent.nousresearch.com/docs/user-guide/features/web-dashboard`.

These fixtures verify client behavior, not deployed-server compatibility, production TLS, native secure-storage durability or UI behavior. No live dashboard was contacted.
