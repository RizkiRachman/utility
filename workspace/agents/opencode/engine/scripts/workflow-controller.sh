#!/usr/bin/env bash
# workflow-controller.sh — central WorkflowPolicy operations.
# Every operation loads+validates the contract, enforces the policy, and writes
# an immutable audit event. State mutation is only performed by transition.sh.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONTRACT="${CONTRACT_FILE:-session/contract.json}"
AUDIT="$(dirname "$CONTRACT")/workflow-audit.jsonl"

OP="${1:-}"; [[ $# -gt 0 ]] && shift
TOOL=""; AGENT=""; TARGET=""; STATUS=""; TO=""; FROM=""; EVIDENCE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tool) TOOL="$2"; shift 2 ;; --agent) AGENT="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;; --status) STATUS="$2"; shift 2 ;;
    --to) TO="$2"; shift 2 ;; --from) FROM="$2"; shift 2 ;;
    --evidence) EVIDENCE="$2"; shift 2 ;;
    *) echo "WorkflowPolicy: unknown arg $1" >&2; exit 2 ;;
  esac
done

STATE="INIT"
if [[ -f "$CONTRACT" ]]; then
  STATE=$(jq -r '.state // "INIT"' "$CONTRACT" 2>/dev/null) || STATE="UNKNOWN"
fi

audit() {
  local op="$1" status="$2" detail="$3"
  mkdir -p "$(dirname "$AUDIT")" 2>/dev/null || true
  jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg op "$op" --arg status "$status" \
    --arg state "$STATE" --arg detail "$detail" \
    '{ts:$ts,op:$op,status:$status,state:$state,detail:$detail}' >> "$AUDIT" 2>/dev/null || true
}
deny() { echo "WorkflowPolicy[$OP]: $1" >&2; audit "$OP" deny "$1"; exit 1; }

case "$OP" in
  pre_tool_action)
    [[ -n "$TOOL" ]] || deny "missing --tool"
    [[ "$STATE" != "UNKNOWN" ]] || deny "contract unparseable"
    [[ "$STATE" != "BLOCKED" ]] || deny "state BLOCKED"
    audit "$OP" allow "$TOOL ${TARGET:-}"; echo "ALLOW tool=$TOOL state=$STATE" ;;
  post_tool_action)
    audit "$OP" "${STATUS:-completed}" "$TOOL"; echo "AUDITED tool=$TOOL" ;;
  pre_delegation)
    [[ -n "$AGENT" ]] || deny "missing --agent"
    [[ "$STATE" != "BLOCKED" && "$STATE" != "UNKNOWN" ]] || deny "state $STATE"
    args=(--contract "$CONTRACT")
    [[ -n "$AGENT" ]] && args+=(--agent "$AGENT")
    bash "$SCRIPT_DIR/state-guard.sh" "${args[@]}" >/dev/null 2>&1 || deny "agent $AGENT not permitted in $STATE"
    audit "$OP" allow "$AGENT"; echo "ALLOW delegation agent=$AGENT state=$STATE" ;;
  post_delegation)
    audit "$OP" "${STATUS:-completed}" "$AGENT"; echo "AUDITED delegation agent=$AGENT" ;;
  pre_transition)
    [[ -n "$TO" ]] || deny "missing --to"
    [[ -n "$EVIDENCE" ]] || deny "evidence id required"
    args=(--contract "$CONTRACT" --to "$TO")
    [[ -n "$AGENT" ]] && args+=(--agent "$AGENT")
    bash "$SCRIPT_DIR/state-guard.sh" "${args[@]}" >/dev/null 2>&1 || deny "illegal transition $STATE -> $TO"
    audit "$OP" allow "$STATE->$TO evidence=$EVIDENCE"; echo "ALLOW transition $STATE -> $TO" ;;
  post_transition)
    audit "$OP" applied "${FROM:-?}->${TO:-?}"; echo "AUDITED transition ${FROM:-?} -> ${TO:-?}" ;;
  pre_completion)
    missing=""
    [[ -f "$(dirname "$CONTRACT")/scores.jsonl" ]] || missing="$missing scores.jsonl"
    if [[ -f "$CONTRACT" ]]; then
      [[ "$(jq -r '.governance.memory_bootstrap.at // empty' "$CONTRACT" 2>/dev/null)" != "" ]] || missing="$missing memory_bootstrap"
      [[ "$(jq -r '.governance.judge_coverage.coverage_pct // 0' "$CONTRACT" 2>/dev/null)" != "0" ]] || missing="$missing judge_coverage"
    fi
    [[ -z "$missing" ]] || deny "incomplete evidence:$missing"
    audit "$OP" allow "completion evidence present"; echo "ALLOW completion" ;;
  *)
    echo "usage: workflow-controller.sh {pre_tool_action|post_tool_action|pre_delegation|post_delegation|pre_transition|post_transition|pre_completion} [flags]" >&2
    exit 2 ;;
esac
