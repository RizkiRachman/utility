#!/usr/bin/env bash
# rag/test.sh — self-contained test suite for the rag MCP server and CLI.
# Covers: CLI index/search/glob/status/get, incremental reindex (change +
# delete), MCP stdio handshake, and the remote embeddings path via a local
# stub. Zero npm dependencies: needs node, curl, sed, grep, coreutils.
# All state lives in /tmp/rag-test-$$ and is removed on exit.
set -u
cd "$(dirname "$0")"   # rag/

PASS=0
FAIL=0
WORK="/tmp/rag-test-$$"
mkdir -p "$WORK"
STUB_PID=""

cleanup() {
  if [ -n "$STUB_PID" ]; then
    kill "$STUB_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# Extract a key=value field from the "index complete:" line.
field() { printf '%s\n' "$1" | sed -n 's/.*'"$2"'=\([0-9]*\).*/\1/p'; }

# Fresh per-case workspace: pristine corpus copy plus its own database.
new_case() {
  CASE="$WORK/$1"
  mkdir -p "$CASE"
  cp -r test/corpus "$CASE/corpus"
  DB="$CASE/rag.db"
}

idx() { RAG_DB="$DB" node server.js index "$CASE/corpus" 2>/dev/null; }
srch() { RAG_DB="$DB" node server.js search "$@" 2>/dev/null; }

echo "== syntax check =="
if node --check server.js && node --check test/upstream-embeddings-stub.js \
  && node --check test/mcp-check.js; then
  pass "syntax check (server.js, stub, mcp-check)"
else
  fail "syntax check"
  echo "passed: $PASS  failed: $FAIL"
  exit 1
fi

# --- Case 1: CLI index reports 3 indexed files, binary skipped, chunks > 3 ---
echo "== case 1: CLI index =="
new_case c1
OUT="$(idx)"
FILES="$(field "$OUT" files)"
CHUNKS="$(field "$OUT" chunks)"
SKIPPED="$(field "$OUT" skipped_binary)"
if [ "$FILES" = "3" ] && [ "$SKIPPED" = "1" ] && [ -n "$CHUNKS" ] && [ "$CHUNKS" -gt 3 ]; then
  pass "case 1: index reports files=3, skipped_binary=1, chunks=$CHUNKS (>3)"
else
  fail "case 1: index stats wrong (files=$FILES skipped=$SKIPPED chunks=$CHUNKS)"
fi

# --- Case 2: search finds the unique phrase, top hit is getting-started.md ---
echo "== case 2: CLI search unique phrase =="
OUT="$(srch "quantum marmalade")"
TOP="$(printf '%s\n' "$OUT" | head -1)"
if printf '%s' "$TOP" | grep -q "getting-started.md" \
  && printf '%s' "$OUT" | grep -q "quantum marmalade"; then
  pass "case 2: top hit is getting-started.md and carries the phrase"
else
  fail "case 2: unexpected result (top: $TOP)"
fi

# --- Case 3: --glob restricts hits to api/users.md ---------------------------
echo "== case 3: CLI search with glob =="
OUT="$(srch "users api rename" --glob "api/*")"
if printf '%s' "$OUT" | grep -q "api/users.md" \
  && ! printf '%s' "$OUT" | grep -q "getting-started.md" \
  && ! printf '%s' "$OUT" | grep -q "format.js"; then
  pass "case 3: glob api/* limits hits to api/users.md"
else
  fail "case 3: glob filter leaked other files"
fi

# --- Case 4: re-index unchanged corpus is a no-op ----------------------------
echo "== case 4: incremental reindex no-op =="
OUT="$(idx)"
RECH="$(field "$OUT" rechunked)"
CHUNKS2="$(field "$OUT" chunks)"
FILES2="$(field "$OUT" files)"
if [ "$RECH" = "0" ] && [ "$CHUNKS2" = "$CHUNKS" ] && [ "$FILES2" = "3" ]; then
  pass "case 4: reindex unchanged (rechunked=0, chunks=$CHUNKS2 stable)"
else
  fail "case 4: reindex not a no-op (rechunked=$RECH chunks=$CHUNKS2 files=$FILES2)"
fi

# --- Case 5: mutate one file, delete another, reindex ------------------------
echo "== case 5: incremental change + delete =="
new_case c5
idx >/dev/null
printf '\n// mutation marker for the reindex test\nfunction mutated() { return 42; }\n' \
  >> "$CASE/corpus/utils/format.js"
rm "$CASE/corpus/api/users.md"
OUT="$(idx)"
RECH="$(field "$OUT" rechunked)"
PURGED="$(field "$OUT" purged)"
ST="$(RAG_DB="$DB" node server.js status 2>/dev/null)"
FILES3="$(printf '%s\n' "$ST" | sed -n 's/^files: \([0-9]*\)$/\1/p')"
GONE="$(srch "rename a user account")"
if [ "$RECH" = "1" ] && [ "$PURGED" = "1" ] && [ "$FILES3" = "2" ] \
  && ! printf '%s' "$GONE" | grep -q "api/users.md"; then
  pass "case 5: changed file re-chunked, deleted file purged (files=$FILES3)"
else
  fail "case 5: incremental state wrong (rechunked=$RECH purged=$PURGED files=$FILES3)"
fi

# --- Case 6: MCP stdio handshake over JSON-RPC lines --------------------------
echo "== case 6: MCP handshake =="
new_case c6
idx >/dev/null
REQ="$WORK/reqs.jsonl"
RESP="$WORK/resp.jsonl"
cat > "$REQ" <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"rag-test","version":"0.0.0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/list"}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"rag_search","arguments":{"query":"quantum marmalade"}}}
EOF
RAG_DB="$DB" node server.js < "$REQ" > "$RESP" 2>/dev/null
if node test/mcp-check.js "$RESP"; then
  pass "case 6: MCP handshake (initialize, tools/list x4, tools/call hits)"
else
  fail "case 6: MCP handshake assertions failed"
fi

# --- Case 7: remote embeddings via stub (dims 8, bearer key) ------------------
echo "== case 7: remote embeddings =="
node test/upstream-embeddings-stub.js >/dev/null 2>&1 &
STUB_PID=$!
READY=0
for _ in $(seq 1 50); do
  if curl -sf http://127.0.0.1:4599/healthz >/dev/null 2>&1; then READY=1; break; fi
  sleep 0.1
done
if [ "$READY" = "1" ]; then
  new_case c7
  OUT="$(RAG_EMBEDDINGS_URL=http://127.0.0.1:4599/v1/embeddings \
    RAG_EMBEDDINGS_MODEL=test-embed RAG_EMBEDDINGS_KEY=testkey \
    RAG_DB="$DB" node server.js index "$CASE/corpus" 2>/dev/null)"
  ST="$(RAG_EMBEDDINGS_URL=http://127.0.0.1:4599/v1/embeddings \
    RAG_EMBEDDINGS_MODEL=test-embed RAG_EMBEDDINGS_KEY=testkey \
    RAG_DB="$DB" node server.js status 2>/dev/null)"
  AUTH="$(curl -s http://127.0.0.1:4599/last-auth)"
  OUT2="$(RAG_EMBEDDINGS_URL=http://127.0.0.1:4599/v1/embeddings \
    RAG_EMBEDDINGS_MODEL=test-embed RAG_EMBEDDINGS_KEY=testkey \
    RAG_DB="$DB" node server.js search "quantum marmalade" 2>/dev/null)"
  TOP="$(printf '%s\n' "$OUT2" | head -1)"
  if printf '%s' "$OUT" | grep -q "mode=remote" \
    && printf '%s\n' "$ST" | grep -q "^embedding_mode: remote$" \
    && printf '%s\n' "$ST" | grep -q "^dims: 8$" \
    && [ "$AUTH" = "Bearer testkey" ] \
    && printf '%s' "$TOP" | grep -q "getting-started.md"; then
    pass "case 7: remote mode indexed (dims=8), bearer key sent, search works"
  else
    fail "case 7: remote mode wrong (out=$OUT auth=$AUTH top=$TOP)"
  fi
else
  fail "case 7: embeddings stub did not become ready"
fi
kill "$STUB_PID" 2>/dev/null || true
STUB_PID=""

# --- Case 8: rag_get returns the full chunk text -------------------------------
echo "== case 8: CLI get =="
new_case c8
idx >/dev/null
OUT="$(RAG_DB="$DB" node server.js get 1 2>/dev/null)"
LINES="$(printf '%s\n' "$OUT" | wc -l)"
if printf '%s\n' "$OUT" | grep -q "^chunk 1:" && [ "$LINES" -gt 1 ]; then
  pass "case 8: get 1 returns metadata header and text ($LINES lines)"
else
  fail "case 8: get 1 returned nothing usable"
fi

echo "----"
echo "passed: $PASS  failed: $FAIL"
if [ "$FAIL" -eq 0 ]; then
  exit 0
fi
exit 1
