# opencode-portal

A landing-page reverse proxy in front of `opencode serve`. You enter the key once on the landing page at `http://127.0.0.1:4097`; the portal validates it, sets a signed HttpOnly cookie, and injects `Authorization: Basic` on every proxied request, including WebSocket upgrade handshakes. OpenCode's own pairing/password screen never appears.

One file, `server.js`, zero npm dependencies: node core modules only (`http`, `crypto`). It runs on the existing `opencode:local` image with this directory bind-mounted read-only, so no image rebuild is needed.

## How it bypasses the pairing screen

OpenCode's serve and web modes protect themselves with HTTP Basic auth (`OPENCODE_SERVER_PASSWORD`), which the browser surfaces as a pairing/password prompt on every first visit. The portal sits in front instead:

1. `GET /` without a valid cookie serves the landing page (dark, monospace, plain form POST, no JavaScript).
2. `POST /portal/login` compares the submitted key against `OPENCODE_SERVER_PASSWORD` with a timing-safe comparison (both sides hashed with SHA256 first, so lengths always match).
3. On success it responds `303` with `Set-Cookie: portal_session=<expiresMs>.<hmac>; HttpOnly; SameSite=Strict; Path=/; Max-Age=...`, where `hmac` is HMAC-SHA256 of the expiry timestamp with `PORTAL_COOKIE_SECRET`.
4. Every later request (and every `Upgrade` handshake) is checked against that cookie, then proxied to `PORTAL_UPSTREAM` with `Authorization: Basic <username>:<password>` injected and the portal cookie stripped. Request and response bodies are piped as streams, so SSE and streaming endpoints work unbuffered. Status, headers, and trailers are forwarded.
5. Unauthenticated requests get `401 {"error":"unauthorized"}` for `/api` paths or JSON-accepting clients, and the landing page for everything else.

Set `PORTAL_AUTO_LOGIN=true` to skip the landing page entirely (the portal proxies immediately and still injects the Authorization header). This is a convenience flag for loopback-only setups.

## Configuration

All variables are optional.

| Variable | Default | Description |
|---|---|---|
| `PORTAL_UPSTREAM` | `http://127.0.0.1:4096` | Upstream OpenCode server (compose sets `http://opencode:4096`) |
| `PORTAL_PORT` | `4097` | Portal listen port |
| `PORTAL_HOST` | `0.0.0.0` | Portal bind address |
| `OPENCODE_SERVER_PASSWORD` | (empty) | The expected key. When empty the portal still gates via cookie but injects no Authorization header |
| `OPENCODE_SERVER_USERNAME` | `opencode` | Username for the injected Basic credential |
| `PORTAL_COOKIE_SECRET` | random at boot | HMAC-SHA256 secret for session cookies. Unset, a random secret is generated and sessions reset on every restart |
| `PORTAL_COOKIE_TTL_HOURS` | `168` | Session lifetime in hours (one week) |
| `PORTAL_AUTO_LOGIN` | `false` | `true` proxies `GET /` without the landing page |
| `PORTAL_SECURE_COOKIE` | `false` | Adds the `Secure` cookie attribute; enable behind TLS termination |
| `PORTAL_VERBOSE` | `false` | `true` logs one line per proxied request |

## Run

```bash
# standalone
OPENCODE_SERVER_PASSWORD=<key> node portal/server.js

# compose stack
docker compose -f docker-compose.example.yaml up -d opencode-portal
```

Endpoints: `GET /portal/health` (JSON `{ok, upstream}`, cookie-gated), `POST /portal/logout` (clears the cookie), `POST /portal/login` (form `key=...` or JSON `{"key": "..."}`).

## Tests

```bash
./portal/test.sh
```

Starts a zero-dependency upstream stub (`test/upstream-stub.js`, ports 4196/4097/4098, all kept local) and asserts the full surface with curl: landing page, 401 JSON gating, wrong key, login cookie, Authorization injection, portal-cookie stripping, tampered-cookie rejection, health probe, SSE streaming, WebSocket upgrade, and auto-login mode. Prints one PASS/FAIL line per case and exits non-zero on any failure.
