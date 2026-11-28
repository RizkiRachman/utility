#!/usr/bin/env bash
# test-governance.sh - governance emitter + FalkorDB ingest regression tests.
# Covers: NDJSON field set, flag-off no-op, never-fails, GRAPH.QUERY mapping,
# offset/idempotence, and unreachable-FalkorDB spool retention.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WORK_DIR="${TMPDIR:-/tmp}/opencode/governance-tests"
PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
assert() { if [[ "$2" == "true" ]]; then pass "$1"; else fail "$1"; fi; }

EMIT="$ENGINE_DIR/scripts/governance-event.sh"
INGEST="$ENGINE_DIR/scripts/governance-graph-ingest.sh"
for f in "$EMIT" "$INGEST"; do
    [[ -f "$f" ]] || { echo "FATAL: missing $f" >&2; exit 1; }
done

rm -rf "$WORK_DIR"; mkdir -p "$WORK_DIR/bin"
SPOOL="$WORK_DIR/spool.jsonl"; STATE="$WORK_DIR/ingest.state"; CAP="$WORK_DIR/redis.capture"

# Mock redis-cli: records argv and can simulate an unreachable DB.
cat > "$WORK_DIR/bin/redis-cli" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${REDIS_CAPTURE:-/dev/null}"
[[ "${MOCK_REDIS_FAIL:-0}" == "1" ]] && exit 1
exit 0
MOCK
chmod +x "$WORK_DIR/bin/redis-cli"

# 1. emitter writes three well-formed events
: > "$SPOOL"
GOVERNANCE_GRAPH_ENABLED=true bash "$EMIT" --event PLAN_SCORED --task T1 --phase PLAN --score 100 --agent system-analyst --evidence ledger:PASS --spool "$SPOOL"
GOVERNANCE_GRAPH_ENABLED=true bash "$EMIT" --event REVIEW_SCORED --task T1 --phase REVIEW --score 88 --agent quality-analyst --extra '{"model":"hy4-flash"}' --spool "$SPOOL"
GOVERNANCE_GRAPH_ENABLED=true bash "$EMIT" --event BLOCKED --task T2 --phase EXECUTE --score 40 --agent orchestrator --spool "$SPOOL"

lines="$(wc -l < "$SPOOL" | tr -d ' ')"
assert "emitter writes 3 NDJSON lines" "$([[ "$lines" -eq 3 ]] && echo true || echo false)"
schema_ok="$(jq -e -s 'length==3 and all(.[]; has("ts") and has("eid") and has("event") and has("score") and has("agent") and has("evidence") and (.extra|type=="object"))' "$SPOOL" >/dev/null 2>&1 && echo true || echo false)"
assert "each line has jq-safe required fields" "$schema_ok"
uids="$(jq -r '.eid' "$SPOOL" | sort -u | wc -l | tr -d ' ')"
assert "event ids are unique" "$([[ "$uids" -eq 3 ]] && echo true || echo false)"

# 2. flag off -> no-op
before="$(wc -l < "$SPOOL" | tr -d ' ')"
GOVERNANCE_GRAPH_ENABLED=false bash "$EMIT" --event COMPLETE --task T1 --spool "$SPOOL"
after="$(wc -l < "$SPOOL" | tr -d ' ')"
assert "GOVERNANCE_GRAPH_ENABLED=false is a no-op" "$([[ "$before" -eq "$after" ]] && echo true || echo false)"

# 3. never fails its caller
GOVERNANCE_GRAPH_ENABLED=true bash "$EMIT" --spool "$SPOOL" >/dev/null 2>&1; rc=$?
assert "emitter exits 0 with no event" "$([[ $rc -eq 0 ]] && echo true || echo false)"
GOVERNANCE_GRAPH_ENABLED=true bash "$EMIT" --event X --extra 'not-json' --spool "$WORK_DIR/extra-spool.jsonl" >/dev/null 2>&1; rc=$?
assert "emitter tolerates invalid --extra" "$([[ $rc -eq 0 ]] && echo true || echo false)"

# 4. ingest maps events to GRAPH.QUERY and records the cursor
: > "$CAP"
PATH="$WORK_DIR/bin:$PATH" REDIS_CAPTURE="$CAP" MOCK_REDIS_FAIL=0 \
    bash "$INGEST" --spool "$SPOOL" --state "$STATE" --graph governance >/dev/null 2>&1
nq="$(grep -c 'GRAPH.QUERY' "$CAP" || true)"
assert "one GRAPH.QUERY per event" "$([[ "$nq" -eq 3 ]] && echo true || echo false)"
mapped="$(grep -q 'TRANSITION' "$CAP" && grep -q 'eid' "$CAP" && echo true || echo false)"
assert "edges are TRANSITION with eid property" "$mapped"
assert "ingest records offset=3" "$(grep -q '^offset=3$' "$STATE" && echo true || echo false)"

# 5. idempotence - second run issues no queries
: > "$CAP"
PATH="$WORK_DIR/bin:$PATH" REDIS_CAPTURE="$CAP" \
    bash "$INGEST" --spool "$SPOOL" --state "$STATE" >/dev/null 2>&1
assert "re-ingest is idempotent (no new queries)" "$([[ ! -s "$CAP" ]] && echo true || echo false)"

# 6. unreachable FalkorDB -> WARN, retain spool, exit 0
before="$(wc -l < "$SPOOL" | tr -d ' ')"
rm -f "$STATE"
warnout="$(PATH="$WORK_DIR/bin:$PATH" REDIS_CAPTURE="$CAP" MOCK_REDIS_FAIL=1 \
    bash "$INGEST" --spool "$SPOOL" --state "$STATE" 2>&1)"; rc=$?
assert "unreachable FalkorDB still exits 0" "$([[ $rc -eq 0 ]] && echo true || echo false)"
assert "unreachable FalkorDB emits WARN" "$(printf '%s' "$warnout" | grep -q 'WARN' && echo true || echo false)"
after="$(wc -l < "$SPOOL" | tr -d ' ')"
assert "unreachable FalkorDB retains spool" "$([[ "$before" -eq "$after" ]] && echo true || echo false)"

rm -rf "$WORK_DIR"
echo "=== governance tests: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
