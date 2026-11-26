#!/usr/bin/env bash
# workflow-controller.sh — central WorkflowPolicy boundary (hardened).
# Every operation loads + schema-checks the contract, applies policy, and
# writes a durable audit event. Audit failure is fail-closed.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONTRACT="${CONTRACT_FILE:-session/contract.json}"
SESSION_DIR="$(dirname "$CONTRACT")"
AUDIT="${AUDIT_FILE:-$SESSION_DIR/workflow-audit.jsonl}"
RULES="${RULES_FILE:-$ENGINE_ROOT/rules/rules.json}"

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

CONTRACT_EXISTS=false
STATE="INIT"
if [[ -f "$CONTRACT" ]]; then
  CONTRACT_EXISTS=true
  parsed=$(jq -r '.state // empty' "$CONTRACT" 2>/dev/null) || parsed=""
  STATE="${parsed:-UNKNOWN}"
fi

ALLOWED_STATES=$(jq -r '[.state_machine.transitions[] | .from, .to] | map(select(. != "*")) | unique | join(" ")' "$RULES" 2>/dev/null || echo "")
state_valid() { [[ " $ALLOWED_STATES " == *" $1 "* ]]; }

# Durable, fail-closed audit. A policy event with no audit record is a denial.
audit() {
  local op="$1" status="$2" detail="$3" line
  mkdir -p "$SESSION_DIR" 2>/dev/null || return 1
  line=$(jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg op "$op" --arg status "$status" \
    --arg state "$STATE" --arg detail "$detail" \
    '{ts:$ts,op:$op,status:$status,state:$state,detail:$detail}') || return 1
  printf '%s\n' "$line" >> "$AUDIT" || return 1
}
allow() {
  audit "$OP" allow "$1" || { echo "WorkflowPolicy[$OP]: audit persistence failed" >&2; exit 1; }
  echo "$2"
}
deny() {
  echo "WorkflowPolicy[$OP]: $1" >&2
  audit "$OP" deny "$1" 2>/dev/null || true
  exit 1
}

# Writes that must never bypass the sanctioned transition command.
protected_target() {
  local t="$1" b
  b=$(basename "$t")
  [[ "$b" == "contract.json" || "$b" == .env* || "$b" == "opencode.json" || "$t" == *"/.session/"* ]]
}

# Evidence must resolve to an artifact, not just be a non-empty string.
resolve_evidence() {
  local ev="$1" kind="${1%%:*}" val="${1#*:}" ledger="$SESSION_DIR/scores.jsonl"
  case "$kind" in
    file)   [[ -f "$val" ]] ;;
    phase)  [[ -f "$ledger" ]] && grep -q -- "\"phase\":\"$val\"" "$ledger" 2>/dev/null ;;
    ledger) [[ -f "$ledger" ]] && grep -q -- "$val" "$ledger" 2>/dev/null ;;
    manual) [[ -n "$val" && ( "$FROM" == "BLOCKED" || "$TO" == "BLOCKED" ) ]] ;;
    *)      [[ -f "$ev" ]] ;;
  esac
}

case "$OP" in
  pre_tool_action)
    [[ -n "$TOOL" ]] || deny "missing --tool"
    [[ "$STATE" != "UNKNOWN" ]] || deny "contract unparseable"
    state_valid "$STATE" || deny "state $STATE not declared in rules.json"
    # A live session (state.md present) must have a contract. Source checkouts may not.
    [[ "$CONTRACT_EXISTS" == true || ! -f "$SESSION_DIR/state.md" ]] || deny "contract missing in live session"
    case "$TOOL" in
      edit|write|patch)
        [[ -n "$TARGET" ]] || deny "missing --target for $TOOL"
        protected_target "$TARGET" && deny "protected target $TARGET (use transition.sh for contract.json)"
        ;;
    esac
    allow "$TOOL ${TARGET:-}" "ALLOW tool=$TOOL state=$STATE" ;;
  post_tool_action)
    allow "$TOOL" "AUDITED tool=$TOOL" ;;
  pre_delegation)
    [[ -n "$AGENT" ]] || deny "missing --agent"
    [[ "$STATE" != "BLOCKED" && "$STATE" != "UNKNOWN" ]] || deny "state $STATE"
    [[ -f "$CONTRACT" ]] || deny "no contract for delegation"
    args=(--contract "$CONTRACT" --agent "$AGENT")
    bash "$SCRIPT_DIR/state-guard.sh" "${args[@]}" >/dev/null 2>&1 || deny "agent $AGENT not permitted in $STATE"
    allow "$AGENT" "ALLOW delegation agent=$AGENT state=$STATE" ;;
  post_delegation)
    allow "$AGENT" "AUDITED delegation agent=$AGENT" ;;
  pre_transition)
    [[ -n "$TO" ]] || deny "missing --to"
    [[ -n "$AGENT" ]] || deny "agent identity required for transition"
    [[ -n "$EVIDENCE" ]] || deny "evidence id required"
    resolve_evidence "$EVIDENCE" || deny "evidence $EVIDENCE does not resolve to an artifact"
    FROM="$STATE"
    args=(--contract "$CONTRACT" --to "$TO" --agent "$AGENT")
    bash "$SCRIPT_DIR/state-guard.sh" "${args[@]}" >/dev/null 2>&1 || deny "illegal transition $STATE -> $TO (agent $AGENT)"
    allow "$STATE->$TO evidence=$EVIDENCE" "ALLOW transition $STATE -> $TO" ;;
  post_transition)
    allow "${FROM:-?}->${TO:-?}" "AUDITED transition ${FROM:-?} -> ${TO:-?}" ;;
  pre_completion)
    missing=""
    ledger="$SESSION_DIR/scores.jsonl"
    [[ -f "$ledger" ]] || missing="$missing scores.jsonl"
    if [[ -f "$CONTRACT" ]]; then
      [[ "$(jq -r '.governance.memory_bootstrap.at // empty' "$CONTRACT" 2>/dev/null)" != "" ]] || missing="$missing memory_bootstrap"
      [[ "$(jq -r '.governance.judge_coverage.judge_backed // 0' "$CONTRACT" 2>/dev/null)" -ge 1 ]] 2>/dev/null || missing="$missing judge_backed_coverage"
    fi
    # At least one judge-backed REVIEW entry, not merely a nonzero score.
    if [[ -f "$ledger" ]]; then
      jq -e -s 'any(.[]; .tier1_only == false and (.phase // "") == "REVIEW")' "$ledger" >/dev/null 2>&1 || missing="$missing judge_backed_REVIEW"
    fi
    # A verified, unexpired learning record must exist.
    if [[ -f "$SESSION_DIR/learning-records.jsonl" ]]; then
      active=$(LEARNING_LOG="$SESSION_DIR/learning-records.jsonl" bash "$SCRIPT_DIR/learning-record.sh" active 2>/dev/null) || active="[]"
      [[ "$(printf '%s' "$active" | jq 'length' 2>/dev/null || echo 0)" -ge 1 ]] || missing="$missing learning_record"
    else
      missing="$missing learning_record"
    fi
    [[ -z "$missing" ]] || deny "incomplete evidence:$missing"
    allow "completion evidence present" "ALLOW completion" ;;
  *)
    echo "usage: workflow-controller.sh {pre_tool_action|post_tool_action|pre_delegation|post_delegation|pre_transition|post_transition|pre_completion} [flags]" >&2
    exit 2 ;;
esac
