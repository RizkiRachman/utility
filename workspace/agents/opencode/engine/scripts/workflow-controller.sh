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
SCHEMA="${SCHEMA_FILE:-$ENGINE_ROOT/contract/contract.schema.json}"

OP="${1:-}"; [[ $# -gt 0 ]] && shift
TOOL=""; AGENT=""; TARGET=""; STATUS=""; TO=""; FROM=""; EVIDENCE=""; CMD=""; ATTEMPT_HASH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tool) TOOL="$2"; shift 2 ;; --agent) AGENT="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;; --status) STATUS="$2"; shift 2 ;;
    --to) TO="$2"; shift 2 ;; --from) FROM="$2"; shift 2 ;;
    --evidence) EVIDENCE="$2"; shift 2 ;; --command) CMD="$2"; shift 2 ;;
    --attempt-hash) ATTEMPT_HASH="$2"; shift 2 ;;
    *) echo "WorkflowPolicy: unknown arg $1" >&2; exit 2 ;;
  esac
done

# Schema gate: full Draft 2020-12 validation. The runtime must provide
# python3-jsonschema; an unavailable validator fails closed.
sha256_stream() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  else shasum -a 256 2>/dev/null | cut -d' ' -f1; fi
}

contract_schema_valid() {
  [[ -f "$SCHEMA" ]] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$SCHEMA" "$CONTRACT" <<'PY' >/dev/null 2>&1
import json, sys
try:
    import jsonschema
except ImportError:
    raise SystemExit(2)
with open(sys.argv[1], encoding="utf-8") as f:
    schema = json.load(f)
with open(sys.argv[2], encoding="utf-8") as f:
    contract = json.load(f)
try:
    jsonschema.Draft202012Validator.check_schema(schema)
    jsonschema.Draft202012Validator(schema).validate(contract)
except Exception:
    raise SystemExit(1)
PY
  [[ $? -eq 0 ]] || return 1
  return 0
}

evidence_kind() { local ev="$1"; printf '%s' "${ev%%:*}"; }

# MCP hosts prefix tool names (server_ctx_patch). Match on tokens, not exact
# names, so a namespaced write cannot slip past the protected-target check.
tool_is_write() {
  local t="${1,,}"
  [[ "$t" =~ (^|[^a-z0-9])(edit|write|patch)([^a-z0-9]|$) ]]
}

phase_evidence_ok() {
  local kind="$1" req
  req=$(jq -r --arg f "$FROM" --arg t "$TO" '
    .enforcement.phase_evidence // {}
    | (.[($f + "->" + $t)] // .["*->" + $t] // .[$f + "->*"] // .default // "file,phase,ledger")
  ' "$RULES" 2>/dev/null)
  [[ ",$req," == *",$kind,"* ]]
}

phase_score_threshold() {
  local phase="$1"
  jq -er --arg from "${phase}_SCORED" '
    [.state_machine.transitions[]
      | select(.from == $from and (.require_score | type == "number"))
      | .require_score]
    | unique
    | if length == 1 then .[0] else error("missing or ambiguous score threshold") end
  ' "$RULES" 2>/dev/null
}

ledger_phase_pass() {
  local ledger="$1" task_id="$2" phase="$3" judge_backed="${4:-false}" threshold
  [[ -f "$ledger" && -n "$task_id" ]] || return 1
  threshold=$(phase_score_threshold "$phase") || return 1
  jq -e -R -s --arg t "$task_id" --arg p "$phase" --argjson judge "$judge_backed" --argjson threshold "$threshold" '
    split("\n") | map(select(length > 0)) | map(try fromjson catch null)
    | map(select(type == "object" and .task_id == $t and .phase == $p))
    | last // null
    | . as $row
    | ($row | type == "object")
      and $row.verdict == "PASS"
      and ($row.combined | type == "number" and . >= $threshold)
      and ($judge == false or $row.tier1_only == false)
  ' "$ledger" >/dev/null 2>&1
}

CONTRACT_EXISTS=false
STATE="INIT"
if [[ -f "$CONTRACT" ]]; then
  CONTRACT_EXISTS=true
  parsed=""
  # post_* ops only append an audit event. No policy decision depends on the
  # schema verdict there, so skip python/jsonschema on the completion half of
  # every tool event. pre_* still validates and fails closed.
  case "$OP" in
    post_*) parsed=$(jq -r '.state // empty' "$CONTRACT" 2>/dev/null) || parsed="" ;;
    *)
      if contract_schema_valid; then
        parsed=$(jq -r '.state // empty' "$CONTRACT" 2>/dev/null) || parsed=""
      fi
      ;;
  esac
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
  local t="$1" resolved b
  if command -v realpath >/dev/null 2>&1; then
    resolved=$(realpath -m -- "$t" 2>/dev/null) || return 0
  else
    resolved=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$t" 2>/dev/null) || return 0
  fi
  b=$(basename "$resolved")
  [[ "$b" == "contract.json" || "$b" == "scores.jsonl" || "$b" == "workflow-audit.jsonl" ||
    "$b" == "tool-audit.jsonl" || "$b" == "loop-state.json" || "$b" == .env* ||
    "$b" == "opencode.json" || "$resolved" == *"/.session/"* || "$resolved" == */.session ]]
}

# Evidence must resolve to an artifact, not just be a non-empty string.
resolve_evidence() {
  local ev="$1" kind="${1%%:*}" val="${1#*:}" ledger="$SESSION_DIR/scores.jsonl"
  local task_id phase
  task_id=$(jq -r '.session.task_id // empty' "$CONTRACT" 2>/dev/null || echo "")
  case "$kind" in
    file)   [[ -f "$val" ]] ;;
    phase)
      [[ -f "$ledger" && -n "$task_id" ]] || return 1
      jq -e -R -s --arg t "$task_id" --arg p "$val" '
        split("\n") | map(select(length > 0)) | map(try fromjson catch null)
        | any(.[]; type == "object" and .task_id == $t and .phase == $p)
      ' "$ledger" >/dev/null 2>&1
      ;;
    ledger)
      [[ -f "$ledger" && -n "$task_id" && "$val" == "PASS" ]] || return 1
      phase="${FROM%_SCORED}"
      ledger_phase_pass "$ledger" "$task_id" "$phase"
      ;;
    manual) [[ -n "$val" && ( "$FROM" == "BLOCKED" || "$TO" == "BLOCKED" ) ]] ;;
    *)      [[ -f "$ev" ]] ;;
  esac
}

# Shell writes to policy artifacts bypass every other boundary; deny them.
protected_shell_write() {
  local cmd="$1" pattern writes=false
  [[ -n "$cmd" ]] || return 1
  case "$cmd" in
    *'>'*|*'mv '*|*'cp '*|*'tee '*|*'sed -i'*|*'rm '*|*'chmod '*|*'chown '*) writes=true ;;
  esac
  [[ "$writes" == true ]] || return 1
  pattern=$(jq -r '.enforcement.shell_policy.protected_patterns[]?' "$RULES" 2>/dev/null)
  [[ -n "$pattern" ]] || pattern=$'contract.json\n.env\nopencode.json\n.session/\nworkflow-audit.jsonl\nscores.jsonl'
  while IFS= read -r p; do
    [[ -n "$p" && "$cmd" == *"$p"* ]] && return 0
  done <<< "$pattern"
  return 1
}

case "$OP" in
  pre_shell)
    [[ -n "$CMD" ]] || deny "missing --command"
    [[ "$STATE" != "UNKNOWN" ]] || deny "contract unparseable"
    state_valid "$STATE" || deny "state $STATE not declared in rules.json"
    protected_shell_write "$CMD" && deny "protected artifact write via shell: $CMD"
    allow "shell ${CMD:0:80}" "ALLOW shell command" ;;
  post_shell)
    allow "shell ${CMD:0:80}" "AUDITED shell ${CMD:0:80}" ;;
  pre_tool_action)
    [[ -n "$TOOL" ]] || deny "missing --tool"
    [[ "$STATE" != "UNKNOWN" ]] || deny "contract unparseable"
    state_valid "$STATE" || deny "state $STATE not declared in rules.json"
    # A live session (state.md present) must have a contract. Source checkouts may not.
    [[ "$CONTRACT_EXISTS" == true || ! -f "$SESSION_DIR/state.md" ]] || deny "contract missing in live session"
    if tool_is_write "$TOOL"; then
      [[ -n "$TARGET" ]] || deny "missing --target for $TOOL"
      protected_target "$TARGET" && deny "protected target $TARGET (use transition.sh for contract.json)"
    fi
    allow "$TOOL ${TARGET:-}" "ALLOW tool=$TOOL state=$STATE" ;;
  post_tool_action)
    allow "$TOOL" "AUDITED tool=$TOOL" ;;
  pre_delegation)
    [[ -n "$AGENT" ]] || deny "missing --agent"
    [[ "$ATTEMPT_HASH" =~ ^[a-fA-F0-9]{64}$ ]] || deny "missing or invalid --attempt-hash"
    [[ "$STATE" != "BLOCKED" && "$STATE" != "UNKNOWN" ]] || deny "state $STATE"
    [[ -f "$CONTRACT" ]] || deny "no contract for delegation"
    args=(--contract "$CONTRACT" --agent "$AGENT")
    bash "$SCRIPT_DIR/state-guard.sh" "${args[@]}" >/dev/null 2>&1 || deny "agent $AGENT not permitted in $STATE"
    loop_diff_hash=""
    if command -v git >/dev/null 2>&1; then
      loop_diff_hash=$(
        {
          printf 'tracked\n'
          git diff HEAD --no-ext-diff --binary 2>/dev/null
          printf '\nuntracked\n'
          git ls-files --others --exclude-standard -z 2>/dev/null |
            while IFS= read -r -d '' path; do
              if command -v sha256sum >/dev/null 2>&1; then sha256sum "$path" 2>/dev/null
              else shasum -a 256 "$path" 2>/dev/null; fi
            done
        } | sha256_stream
      )
    fi
    loop_task=$(jq -r '.session.task_id // "unknown"' "$CONTRACT" 2>/dev/null || echo unknown)
    loop_hash=$(printf '%s\n' "$loop_task" "$STATE" "$AGENT" "$ATTEMPT_HASH" "$loop_diff_hash" | sha256_stream)
    [[ "$loop_hash" =~ ^[a-fA-F0-9]{64}$ ]] || deny "unable to fingerprint delegation attempt"
    loop_rc=0
    bash "$SCRIPT_DIR/loop-guard.sh" \
      --contract "$CONTRACT" --state "$SESSION_DIR/loop-state.json" \
      --task "$loop_task" --phase "$STATE" --hash "$loop_hash" >/dev/null 2>&1 || loop_rc=$?
    if [[ "$loop_rc" -eq 2 ]]; then
      deny "identical delegation attempt hash: change approach"
    elif [[ "$loop_rc" -eq 3 ]]; then
      deny "delegation loop limit exceeded"
    elif [[ "$loop_rc" -ne 0 ]]; then
      deny "loop guard unavailable or invalid"
    fi
    allow "$AGENT" "ALLOW delegation agent=$AGENT state=$STATE" ;;
  post_delegation)
    allow "$AGENT" "AUDITED delegation agent=$AGENT" ;;
  pre_transition)
    [[ -n "$TO" ]] || deny "missing --to"
    [[ -n "$AGENT" ]] || deny "agent identity required for transition"
    [[ -n "$EVIDENCE" ]] || deny "evidence id required"
    [[ "$STATE" != "UNKNOWN" ]] || deny "contract is invalid or does not satisfy its schema"
    state_valid "$STATE" || deny "state $STATE not declared in rules.json"
    FROM="$STATE"
    phase_evidence_ok "$(evidence_kind "$EVIDENCE")" || deny "evidence kind not permitted for $FROM->$TO"
    resolve_evidence "$EVIDENCE" || deny "evidence $EVIDENCE does not resolve to an artifact"
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
    # Completion evidence must belong to this task; stale ledger rows from a
    # prior task cannot satisfy the current task's gates.
    task_id=$(jq -r '.session.task_id // empty' "$CONTRACT" 2>/dev/null || echo "")
    [[ -n "$task_id" ]] || missing="$missing task_id"
    for phase in PLAN EXECUTE REVIEW; do
      if [[ -n "$task_id" ]]; then
        judge_backed=false
        [[ "$phase" != "REVIEW" ]] || judge_backed=true
        ledger_phase_pass "$ledger" "$task_id" "$phase" "$judge_backed" || {
          if [[ "$phase" == "REVIEW" ]]; then missing="$missing judge_backed_REVIEW"
          else missing="$missing ledger_${phase}"; fi
        }
      fi
    done
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
    echo "usage: workflow-controller.sh {pre_shell|post_shell|pre_tool_action|post_tool_action|pre_delegation|post_delegation|pre_transition|post_transition|pre_completion} [flags]" >&2
    exit 2 ;;
esac
