#!/usr/bin/env bash
# governance-graph-ingest.sh - drain governance-events.jsonl into FalkorDB.
#
# Reads the NDJSON spool written by governance-event.sh (one event per line),
# creates (Task)-[:TRANSITION {eid,ts,event,score,agent,evidence,extra}]->(State)
# edges via `redis-cli GRAPH.QUERY`, and records a cursor + seen-eid set so
# re-runs are idempotent. Unreachable FalkorDB -> loud WARN, spool retained,
# exit 0 (ingestion is best-effort and must never break a caller).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/paths.sh
source "$SCRIPT_DIR/lib/paths.sh" 2>/dev/null || true
PROJECT_ROOT="$(resolve_project_root "$SCRIPT_DIR/..")"
SESSION_DIR="$(resolve_session_dir "$PROJECT_ROOT")"
SPOOL="$SESSION_DIR/governance-events.jsonl"
STATE="$SESSION_DIR/governance-ingest.state"
GRAPH="${GOVERNANCE_GRAPH:-governance}"
HOST="${FALKORDB_HOST:-falkordb}"
PORT="${FALKORDB_PORT:-6379}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --spool) SPOOL="${2:-}"; shift 2 ;;
        --state) STATE="${2:-}"; shift 2 ;;
        --graph) GRAPH="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,9p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) shift ;;
    esac
done

command -v jq >/dev/null 2>&1 || { echo "[WARN] jq missing; governance spool retained" >&2; exit 0; }
command -v redis-cli >/dev/null 2>&1 || { echo "[WARN] redis-cli missing; governance spool retained" >&2; exit 0; }
[[ -f "$SPOOL" ]] || exit 0

offset=0
if [[ -f "$STATE" ]]; then
    offset="$(grep '^offset=' "$STATE" 2>/dev/null | tail -1 | cut -d= -f2 || true)"
fi
[[ "$offset" =~ ^[0-9]+$ ]] || offset=0

declare -A seen=()
if [[ -f "$STATE" ]]; then
    while IFS= read -r e; do
        [[ -n "$e" ]] && seen["$e"]=1
    done < <(grep '^eid=' "$STATE" 2>/dev/null | cut -d= -f2- || true)
fi

# Cypher-safe literal: jq emits a double-quoted JSON string (valid openCypher literal).
cq() { printf '%s' "${1:-}" | jq -Rs . 2>/dev/null || printf '""'; }

idx=0
processed="$offset"
queries=0
warned=false
while IFS= read -r line || [[ -n "$line" ]]; do
    idx=$((idx + 1))
    [[ "$idx" -le "$offset" ]] && continue
    [[ -z "$line" ]] && continue

    eid="$(printf '%s' "$line" | jq -r '.eid // empty' 2>/dev/null || true)"
    if [[ -z "$eid" || -n "${seen[$eid]:-}" ]]; then
        processed="$idx"
        continue
    fi

    event="$(printf '%s' "$line" | jq -r '.event // ""' 2>/dev/null || true)"
    task="$(printf '%s'  "$line" | jq -r '.task // ""' 2>/dev/null || true)"
    phase="$(printf '%s' "$line" | jq -r '.phase // ""' 2>/dev/null || true)"
    score="$(printf '%s' "$line" | jq -r '.score // ""' 2>/dev/null || true)"
    agent="$(printf '%s' "$line" | jq -r '.agent // ""' 2>/dev/null || true)"
    evidence="$(printf '%s' "$line" | jq -r '.evidence // ""' 2>/dev/null || true)"
    ts="$(printf '%s'     "$line" | jq -r '.ts // ""' 2>/dev/null || true)"
    extra="$(printf '%s'  "$line" | jq -c '.extra // {}' 2>/dev/null || printf '{}')"

    cypher="MERGE (t:Task {name: $(cq "$task")}) MERGE (s:State {name: $(cq "$event")}) MERGE (t)-[e:TRANSITION {eid: $(cq "$eid")}]->(s) SET e.ts=$(cq "$ts"), e.event=$(cq "$event"), e.phase=$(cq "$phase"), e.score=$(cq "$score"), e.agent=$(cq "$agent"), e.evidence=$(cq "$evidence"), e.extra=$(cq "$extra")"

    if redis-cli -h "$HOST" -p "$PORT" GRAPH.QUERY "$GRAPH" "$cypher" >/dev/null 2>&1; then
        seen["$eid"]=1
        processed="$idx"
        queries=$((queries + 1))
    else
        if [[ "$warned" == false ]]; then
            echo "[WARN] FalkorDB unreachable at ${HOST}:${PORT}; governance spool retained (offset stays ${offset})" >&2
            warned=true
        fi
        break
    fi
done < "$SPOOL"

if (( queries > 0 )); then
    tmp="$STATE.tmp.$$"
    {
        printf 'offset=%s\n' "$processed"
        for e in "${!seen[@]}"; do printf 'eid=%s\n' "$e"; done
    } > "$tmp" 2>/dev/null && mv "$tmp" "$STATE" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
fi

exit 0
