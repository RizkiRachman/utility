#!/usr/bin/env bash
# OpenCode Portal test suite.
#
# Starts a zero-dependency node upstream stub plus two portal instances
# (one normal, one with PORTAL_AUTO_LOGIN=true), then asserts portal
# behavior end to end with curl + grep. Exits non-zero on any failure.
#
# Usage: ./portal/test.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Avoid 4096: a live opencode serve often occupies it; the stub is isolated.
STUB_PORT=4196
PORTAL_PORT=4097
AUTO_PORT=4098
BASE="http://127.0.0.1:${PORTAL_PORT}"
AUTO_BASE="http://127.0.0.1:${AUTO_PORT}"
COOKIE_JAR="$(mktemp)"
LOG_DIR="$(mktemp -d)"
STUB_PID=""
PORTAL_PID=""
AUTO_PID=""
PASS=0
FAIL=0

cleanup() {
  [[ -n "$AUTO_PID" ]] && kill "$AUTO_PID" 2>/dev/null
  [[ -n "$PORTAL_PID" ]] && kill "$PORTAL_PID" 2>/dev/null
  [[ -n "$STUB_PID" ]] && kill "$STUB_PID" 2>/dev/null
  rm -rf "$LOG_DIR" "$COOKIE_JAR" "${COOKIE_JAR}.auto"
}
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

# wait_for <url> <label>: retry until curl gets any HTTP response (max ~5s)
wait_for() {
  local url="$1" label="$2" i
  for i in $(seq 1 50); do
    if curl -s -o /dev/null "$url"; then
      return 0
    fi
    sleep 0.1
  done
  echo "FAIL: $label did not become ready at $url"
  exit 1
}

# ---------------------------------------------------------------- launches --
if curl -s -o /dev/null --max-time 1 "http://127.0.0.1:${STUB_PORT}/" \
  || curl -s -o /dev/null --max-time 1 "$BASE/" \
  || curl -s -o /dev/null --max-time 1 "$AUTO_BASE/"; then
  echo "FAIL: test ports ${STUB_PORT}/${PORTAL_PORT}/${AUTO_PORT} not all free; stop the conflicting processes first"
  exit 1
fi
UPSTREAM_PORT="$STUB_PORT" node "$ROOT/test/upstream-stub.js" >"$LOG_DIR/stub.log" 2>&1 &
STUB_PID=$!
PORTAL_UPSTREAM="http://127.0.0.1:${STUB_PORT}" \
OPENCODE_SERVER_PASSWORD=testpass \
PORTAL_COOKIE_SECRET=testsecret \
PORTAL_PORT="$PORTAL_PORT" \
node "$ROOT/server.js" >"$LOG_DIR/portal.log" 2>&1 &
PORTAL_PID=$!
PORTAL_AUTO_LOGIN=true \
PORTAL_UPSTREAM="http://127.0.0.1:${STUB_PORT}" \
OPENCODE_SERVER_PASSWORD=testpass \
PORTAL_COOKIE_SECRET=testsecret \
PORTAL_PORT="$AUTO_PORT" \
node "$ROOT/server.js" >"$LOG_DIR/portal-auto.log" 2>&1 &
AUTO_PID=$!

wait_for "http://127.0.0.1:${STUB_PORT}/" "upstream stub"
wait_for "$BASE/portal/health" "portal"

# ------------------------------------------------------------------- cases --

# 1. GET / unauthenticated -> landing page
body="$(curl -s "$BASE/")"
if grep -q 'OpenCode Portal' <<<"$body"; then
  pass "1. unauthenticated GET / serves landing page"
else
  fail "1. unauthenticated GET / did not serve landing page: $(head -c 200 <<<"$body")"
fi

# 2. GET /api/anything unauthenticated -> 401 JSON
code="$(curl -s -o "$LOG_DIR/body2" -w '%{http_code}' "$BASE/api/anything")"
if [[ "$code" == "401" ]] && grep -q '"error":"unauthorized"' "$LOG_DIR/body2"; then
  pass "2. unauthenticated GET /api/anything -> 401 JSON"
else
  fail "2. unauthenticated GET /api/anything -> code=$code body=$(cat "$LOG_DIR/body2")"
fi

# 2b. JSON accept header unauthenticated -> 401 JSON
code="$(curl -s -o "$LOG_DIR/body2b" -w '%{http_code}' -H 'Accept: application/json' "$BASE/")"
if [[ "$code" == "401" ]] && grep -q '"error":"unauthorized"' "$LOG_DIR/body2b"; then
  pass "2b. unauthenticated GET / with Accept: application/json -> 401 JSON"
else
  fail "2b. unauthenticated JSON accept -> code=$code body=$(cat "$LOG_DIR/body2b")"
fi

# 3. POST /portal/login wrong key -> 401 with error marker
code="$(curl -s -o "$LOG_DIR/body3" -w '%{http_code}' -X POST --data-urlencode 'key=wrongpass' "$BASE/portal/login")"
if [[ "$code" == "401" ]] && grep -q 'class="error"' "$LOG_DIR/body3"; then
  pass "3. wrong key -> 401 landing page with error marker"
else
  fail "3. wrong key -> code=$code"
fi

# 4. POST /portal/login correct key -> 303 with Set-Cookie portal_session
headers="$(curl -s -D - -o /dev/null -c "$COOKIE_JAR" -X POST --data-urlencode 'key=testpass' "$BASE/portal/login")"
if grep -q '^HTTP.* 303' <<<"$headers" && grep -qi 'set-cookie: portal_session=' <<<"$headers"; then
  pass "4. correct key -> 303 with portal_session cookie"
else
  fail "4. correct key response headers: $(echo "$headers" | head -5)"
fi

# 5. GET / with cookie -> proxied to upstream
body="$(curl -s -b "$COOKIE_JAR" "$BASE/")"
if grep -q 'UPSTREAM-OK' <<<"$body"; then
  pass "5. GET / with cookie proxies to upstream"
else
  fail "5. GET / with cookie did not reach upstream: $(head -c 200 <<<"$body")"
fi

# 6. GET /echo with cookie -> Authorization injected, portal cookie stripped
expected_auth="$(printf 'opencode:testpass' | base64)"
body="$(curl -s -b "$COOKIE_JAR" "$BASE/echo")"
if grep -q "\"authorization\": \"Basic ${expected_auth}\"" <<<"$body" \
  && ! grep -q 'portal_session' <<<"$body"; then
  pass "6. /echo shows injected Authorization and no portal_session cookie"
else
  fail "6. /echo headers: $(head -c 400 <<<"$body")"
fi

# 7. Tampered cookie -> landing page again
body="$(curl -s -H 'Cookie: portal_session=9999999999999.0000000000000000000000000000000000000000000000000000000000000000' "$BASE/")"
if grep -q 'OpenCode Portal' <<<"$body"; then
  pass "7. tampered cookie falls back to landing page"
else
  fail "7. tampered cookie was accepted: $(head -c 200 <<<"$body")"
fi

# 8. /portal/health with cookie -> ok:true upstream:true
body="$(curl -s -b "$COOKIE_JAR" "$BASE/portal/health")"
if grep -q '"ok":true' <<<"$body" && grep -q '"upstream":true' <<<"$body"; then
  pass "8. /portal/health reports ok and upstream reachable"
else
  fail "8. /portal/health body: $body"
fi

# 9. SSE streams through without buffering (timeout bounded)
body="$(curl -s -N --max-time 10 -b "$COOKIE_JAR" "$BASE/sse")"
if grep -q 'event-3' <<<"$body"; then
  pass "9. SSE streams all events through the portal"
else
  fail "9. SSE body incomplete: $(head -c 200 <<<"$body")"
fi

# 10. WebSocket upgrade with cookie -> 101 from upstream
body="$(curl -s -i --http1.1 --max-time 10 -b "$COOKIE_JAR" \
  -H 'Upgrade: websocket' -H 'Connection: Upgrade' \
  -H 'Sec-WebSocket-Key: x' -H 'Sec-WebSocket-Version: 13' \
  "$BASE/ws")"
if grep -q 'HTTP/1.1 101' <<<"$body"; then
  pass "10. websocket upgrade returns 101 through the portal"
else
  fail "10. upgrade response: $(head -c 300 <<<"$body")"
fi

# 11. PORTAL_AUTO_LOGIN=true portal -> GET / without cookie reaches upstream
body="$(curl -s "$AUTO_BASE/")"
if grep -q 'UPSTREAM-OK' <<<"$body"; then
  pass "11. auto-login portal proxies GET / without a cookie"
else
  fail "11. auto-login portal body: $(head -c 200 <<<"$body")"
fi

# ------------------------------------------------------------------ report --
echo "----------------------------------------"
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -ne 0 ]]; then
  echo "--- portal.log ---"; cat "$LOG_DIR/portal.log" 2>/dev/null
  echo "--- stub.log ---"; cat "$LOG_DIR/stub.log" 2>/dev/null
  exit 1
fi
exit 0
