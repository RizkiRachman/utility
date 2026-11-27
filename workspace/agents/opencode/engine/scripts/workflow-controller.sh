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
TOOL=""; AGENT=""; TARGET=""; STATUS=""; TO=""; FROM=""; EVIDENCE=""; CMD=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tool) TOOL="$2"; shift 2 ;; --agent) AGENT="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;; --status) STATUS="$2"; shift 2 ;;
    --to) TO="$2"; shift 2 ;; --from) FROM="$2"; shift 2 ;;
    --evidence) EVIDENCE="$2"; shift 2 ;; --command) CMD="$2"; shift 2 ;;
    *) echo "WorkflowPolicy: unknown arg $1" >&2; exit 2 ;;
  esac
done

# Full schema gate: parseable JSON plus every top-level and nested required
# key declared in contract.schema.json. A valid state in a partial contract is
# not enough to pass the controller.
# Schema gate: parseable JSON, every top-level and nested required key, and the
# declared top-level type for each required property. A missing or unparseable
# schema fails closed. Not full JSON Schema: enums, formats, and patterns are
# unchecked; see doc/efficiency-limits.md.
# Schema gate: parseable JSON, every top-level and nested required key, the
# declared top-level type for each required property, and the enum and pattern
# constraints the schema declares (absent values are skipped). A missing or
# unparseable schema fails closed. Not full JSON Schema: formats and numeric
# ranges are unchecked; see doc/efficiency-limits.md.
contract_schema_valid() {
  local key want section
  [[ -f "$SCHEMA" ]] || return 1
  jq -e . "$SCHEMA" >/dev/null 2>&1 || return 1
  jq -e . "$CONTRACT" >/dev/null 2>&1 || return 1
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$SCHEMA" "$CONTRACT" <<'PY' >/dev/null 2>&1
import json, sys
try:
    import jsonschema
except Exception:
    raise SystemExit(0)
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
  fi
  while IFS= read -r key; do
    [[ -n "$key" ]] && jq -e --arg k "$key" 'has($k)' "$CONTRACT" >/dev/null 2>&1 || return 1
  done < <(jq -r '.required[]?' "$SCHEMA" 2>/dev/null)
  while IFS=$'\t' read -r key want; do
    [[ -n "$key" && -n "$want" ]] || continue
    jq -e --arg k "$key" --arg t "$want" '.[$k] | type == $t or ($t == "number" and type == "integer")' "$CONTRACT" >/dev/null 2>&1 || return 1
  done < <(jq -r '.properties | to_entries[] | select(.value.required and .value.type) | "\(.key)\t\(.value.type)"' "$SCHEMA" 2>/dev/null)
  while IFS=$'\t' read -r section key; do
    [[ -n "$section" && -n "$key" ]] || continue
    jq -e --arg s "$section" --arg k "$key" '.[$s] | type == "object" and has($k)' "$CONTRACT" >/dev/null 2>&1 || return 1
  done < <(jq -r '.properties | to_entries[] | select(.value.required) | .key as $s | .value.required[] | [$s, .] | @tsv' "$SCHEMA" 2>/dev/null)
  while IFS=$'\t' read -r key want; do
    [[ -n "$key" && -n "$want" ]] || continue
    jq -e --arg k "$key" --argjson a "$want" '.[$k] as $v | ($v | type) == "null" or ($a | index($v) != null)' "$CONTRACT" >/dev/null 2>&1 || return 1
  done < <(jq -r '.properties | to_entries[] | select(.value.enum) | "\(.key)\t\(.value.enum | tojson)"' "$SCHEMA" 2>/dev/null)
  while IFS=$'\t' read -r key want; do
    [[ -n "$key" && -n "$want" ]] || continue
    jq -e --arg k "$key" --arg p "$want" '.[$k] as $v | ($v | type) == "null" or (($v | type) == "string" and ($v | test($p)))' "$CONTRACT" >/dev/null 2>&1 || return 1
  done < <(jq -r '.properties | to_entries[] | select(.value.pattern) | "\(.key)\t\(.value.pattern)"' "$SCHEMA" 2>/dev/null)
  while IFS=$'\t' read -r section key want; do
    [[ -n "$section" && -n "$key" && -n "$want" ]] || continue
    jq -e --arg s "$section" --arg k "$key" --argjson a "$want" '.[$s][$k] as $v | ($v | type) == "null" or ($a | index($v) != null)' "$CONTRACT" >/dev/null 2>&1 || return 1
  done < <(jq -r '.properties | to_entries[] | .key as $s | (.value.properties // {}) | to_entries[] | select(.value.enum) | "\($s)\t\(.key)\t\(.value.enum | tojson)"' "$SCHEMA" 2>/dev/null)
  while IFS=$'\t' read -r section key want; do
    [[ -n "$section" && -n "$key" && -n "$want" ]] || continue
    jq -e --arg s "$section" --arg k "$key" --arg p "$want" '.[$s][$k] as $v | ($v | type) == "null" or (($v | type) == "string" and ($v | test($p)))' "$CONTRACT" >/dev/null 2>&1 || return 1
  done < <(jq -r '.properties | to_entries[] | .key as $s | (.value.properties // {}) | to_entries[] | select(.value.pattern) | "\($s)\t\(.key)\t\(.value.pattern)"' "$SCHEMA" 2>/dev/null)
  return 0
}

evidence_kind() { local ev="$1"; printf '%s' "${ev%%:*}"; }

phase_evidence_ok() {
  local kind="$1" req
  req=$(jq -r --arg f "$FROM" --arg t "$TO" '
    .enforcement.phase_evidence // {}
    | (.[($f + "->" + $t)] // .["*->" + $t] // .[$f + "->*"] // .default // "file,phase,ledger")
  ' "$RULES" 2>/dev/null)
  [[ ",$req," == *",$kind,"* ]]
}

CONTRACT_EXISTS=false
STATE="INIT"
if [[ -f "$CONTRACT" ]]; then
  CONTRACT_EXISTS=true
  if contract_schema_valid; then
    parsed=$(jq -r '.state // empty' "$CONTRACT" 2>/dev/null) || parsed=""
    STATE="${parsed:-UNKNOWN}"
  else
    STATE="UNKNOWN"
  fi
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

# Shell writes to policy artifacts bypass every other boundary; deny them.
protected_shell_write() {
  local cmd="$1" pattern writes=false
  [[ -n "$cmd" ]] || return 1
  case "$cmd" in
    *'>'*|*'mv '*|*'cp '*|*'tee '*|*'sed -i'*|*'jq '*|*'rm '*|*'chmod '*|*'chown '*) writes=true ;;
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
    loop_hash=""
    if command -v git >/dev/null 2>&1; then
      loop_hash=$(git diff --no-ext-diff --binary 2>/dev/null | sha256sum 2>/dev/null | cut -d' ' -f1)
      [[ -n "$loop_hash" ]] || loop_hash=$(git diff --no-ext-diff --binary 2>/dev/null | shasum -a 256 2>/dev/null | cut -d' ' -f1)
    fi
    loop_task=$(jq -r '.session.task_id // "unknown"' "$CONTRACT" 2>/dev/null || echo unknown)
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
    # A malformed row must not block or falsely satisfy any ledger check.
    if [[ -f "$ledger" ]]; then
      jq -e -R -s 'split("\n") | map(select(length > 0)) | map(try fromjson catch null)
        | any(.[]; type == "object" and .tier1_only == false and (.phase // "") == "REVIEW")' "$ledger" >/dev/null 2>&1 || missing="$missing judge_backed_REVIEW"
    fi
    # Every scored phase must have run and written a ledger entry.
    task_id=""
    [[ -f "$CONTRACT" ]] && task_id=$(jq -r '.session.task_id // empty' "$CONTRACT" 2>/dev/null || echo "")
    for phase in PLAN EXECUTE REVIEW; do
      if [[ -n "$task_id" ]]; then
        jq -e -R -s --arg p "$phase" --arg t "$task_id" 'split("\n") | map(select(length > 0)) | map(try fromjson catch null)
          | any(.[]; type == "object" and (.phase // "") == $p and (.task_id // "") == $t)' "$ledger" >/dev/null 2>&1 || missing="$missing ledger_${phase}"
      else
        jq -e -R -s --arg p "$phase" 'split("\n") | map(select(length > 0)) | map(try fromjson catch null)
          | any(.[]; type == "object" and (.phase // "") == $p)' "$ledger" >/dev/null 2>&1 || missing="$missing ledger_${phase}"
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
