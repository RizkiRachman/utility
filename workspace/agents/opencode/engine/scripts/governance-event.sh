#!/usr/bin/env bash
# governance-event.sh - append one governance transition event to the NDJSON spool.
#
# Best-effort by design: this emitter never fails its caller. Every error
# path exits 0. Set GOVERNANCE_GRAPH_ENABLED=false to disable graph capture
# entirely (the emitter becomes a no-op).
#
# Usage:
#   governance-event.sh --event PLAN_SCORED [--task TASK_ID] [--phase PHASE]
#     [--score SCORE] [--agent AGENT] [--evidence EVIDENCE] [--extra JSON]
#     [--spool PATH]
#
# Fields emitted (jq-safe): ts, eid, event, task, phase, score, agent,
# evidence, extra (extra is always a JSON object).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/paths.sh
source "$SCRIPT_DIR/lib/paths.sh" 2>/dev/null || true

PROJECT_ROOT="$(resolve_project_root "$SCRIPT_DIR/..")"
SESSION_DIR="$(resolve_session_dir "$PROJECT_ROOT")"
SPOOL="$SESSION_DIR/governance-events.jsonl"

EVENT="" TASK="" PHASE="" SCORE="" AGENT="" EVIDENCE="" EXTRA="{}"
ENABLED="${GOVERNANCE_GRAPH_ENABLED:-true}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --event)    EVENT="${2:-}"; shift 2 ;;
        --task)     TASK="${2:-}"; shift 2 ;;
        --phase)    PHASE="${2:-}"; shift 2 ;;
        --score)    SCORE="${2:-}"; shift 2 ;;
        --agent)    AGENT="${2:-}"; shift 2 ;;
        --evidence) EVIDENCE="${2:-}"; shift 2 ;;
        --extra)    EXTRA="${2:-}"; shift 2 ;;
        --spool)    SPOOL="${2:-}"; shift 2 ;;
        -h|--help)  sed -n '2,12p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) shift ;;
    esac
done

# Disabled or nothing to emit -> clean no-op.
[[ "$ENABLED" == "true" ]] || exit 0
[[ -n "$EVENT" ]] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

mkdir -p "$(dirname "$SPOOL")" 2>/dev/null || exit 0

ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
seed="${EVENT}|${TASK}|${PHASE}|${ts}|$$|${RANDOM}"
eid="$(printf '%s' "$seed" | sha256sum 2>/dev/null | cut -d' ' -f1 || true)"
[[ -z "$eid" ]] && eid="${ts}-$$-${RANDOM}"

extra_json="$(printf '%s' "$EXTRA" | jq -c 'if type == "object" then . else {value: .} end' 2>/dev/null || printf '{}')"

line="$(jq -n -c \
    --arg ts "$ts" --arg eid "$eid" --arg event "$EVENT" \
    --arg task "$TASK" --arg phase "$PHASE" --arg score "$SCORE" \
    --arg agent "$AGENT" --arg evidence "$EVIDENCE" \
    --argjson extra "$extra_json" \
    '{ts:$ts,eid:$eid,event:$event,task:$task,phase:$phase,score:$score,agent:$agent,evidence:$evidence,extra:$extra}' 2>/dev/null)" || exit 0

printf '%s\n' "$line" >> "$SPOOL" 2>/dev/null || true
exit 0
