# Controlled Hermes source evidence

The integration probe imports the original installed server at `/opt/hermes` read-only. It is not a Git checkout; no upstream revision is inferred. SHA-256 values were freshly read during integration:

| Original file | SHA-256 |
| --- | --- |
| `gateway/platforms/api_server.py` | `73175d668c0c683209ad047191921fe899e84b8a429470081a718ae7d163d3f6` |
| `gateway/platforms/api_server_runs.py` | `565f0570cd1ff771590534586bdb6841cd86530c8e0728ce6e036597cc2a50a6` |
| `gateway/session_api.py` | `77ef3e7fa9214cd2b8bdcc4e8b6f7c95cf95f8137e307f5225656dfa8b4a8f7e` |
| `tui_gateway/contracts/canonical_sessions.py` | `b6f9d9e4f0ef233b386f5dd56e406f4168c3e123abc892300e4f256d7f8eac4a` |

`tool/hermes_controlled_server.py` uses the original capability/HTTP route table, Runs, SSE and SessionDB, replacing only agent construction with a deterministic non-inferencing checkpoint agent. Its subprocess clears inherited environment, requires an empty isolated HERMES_HOME, binds ephemeral loopback, and uses fake local authentication. No production key, signing identity or paid provider is used.

The actual ChatHome probe selects an externally created API-owned conversation, continues it, sends only new input and the original session ID, renders actual official SSE text, sends Guide, reconciles terminal status into the same journal, then reads back the exact authoritative server history. This passed separately from the normal hermetic suite.

This evidence is **legacy API-server mode**, not canonical TurnRunner, a deployed remote gateway, paid inference, an APK or device verification. Desktop/CLI attachment still requires a host-issued mobile bootstrap/grant flow and lifecycle-bound canonical gateway integration. It remains explicitly open.
