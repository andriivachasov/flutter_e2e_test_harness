# Polling, websockets, SSE, push — same assertions

The reference app polls (D8) to stay inside HTTP/1+JSON. The test never
depends on the transport: it asserts that the *other user's effect becomes
visible in the UI* within a deadline (`waitForMessage($, text, timeout:
60 s)`). That assertion is identical for:

| Transport | What the app does | What the test does |
|---|---|---|
| Polling | timer → GET → `setState` on change | `waitVisible` on the new item |
| WebSocket / SSE | stream → `setState` per message | same |
| Push (FCM/APNs) | notification → fetch → `setState` | same, plus a longer deadline; delivery to simulators is not deterministic (`simctl push` on iOS is a documented `[later]` recipe) |

Rules that keep this true:

- The UI is the oracle. Don't assert on sockets or notification payloads.
- The app must be frame-quiet between updates (only `setState` on real
  change), whatever the transport.
- Reconnect logic is part of the product: if the backend restarts
  mid-test (the harness aborts the run then), the *next* run starts from a
  cold app anyway (R9a).
- Backend-side, real-time delivery needs the same per-user isolation:
  route events by user, and sharded tests never see each other.
