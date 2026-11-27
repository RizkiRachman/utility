#!/usr/bin/env bash
# scripts/loop-guard.sh - C3: controller-enforced loop iteration cap + changed-
# approach retry hash. The CONTROLLER runs this (orchestrator, before each
# delegation and after every *_SCORED verdict); agents never self-exempt.
# Deterministic, file-based (session/loop-state.json), no daemon. State
# read/check/write is serialized; lock timeout fails closed.
#
# Exit codes: 0 = ok | 2 = force-changed-approach (identical attempt hash)
#             3 = BLOCKED (max_loop_iterations exceeded)
# On 2/3 a JSON directive is printed for retry.issues[] / state transition.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CONTRACT="session/contract.json"
STATE="session/loop-state.json"
MAX=""; TASK=""; PHASE=""; HASH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task) TASK="$2"; shift 2 ;;
    --phase) PHASE="$2"; shift 2 ;;
    --hash) HASH="$2"; shift 2 ;;
    --max) MAX="$2"; shift 2 ;;
    --contract) CONTRACT="$2"; shift 2 ;;
    --state) STATE="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done
[[ -f "$CONTRACT" ]] || { echo "{\"action\":\"error\",\"reason\":\"contract not found: $CONTRACT\"}"; exit 64; }
RULES="${RULES_PATH:-$SCRIPT_DIR/../rules/rules.json}"
configured_max=$(jq -er '
  .enforcement.loop_guard.max_loop_iterations // 12
  | select(type == "number" and floor == . and . > 0)
' "$RULES" 2>/dev/null) || {
  echo "{\"action\":\"error\",\"reason\":\"invalid configured max_loop_iterations\"}"
  exit 64
}
MAX="${MAX:-$configured_max}"
task_id="${TASK:-$(jq -r '.session.task_id // "unknown"' "$CONTRACT" 2>/dev/null || echo unknown)}"
[[ "$MAX" =~ ^[1-9][0-9]*$ ]] || { echo "{\"action\":\"error\",\"reason\":\"invalid max_loop_iterations: $MAX\"}"; exit 64; }
(( MAX <= configured_max )) || {
  echo "{\"action\":\"error\",\"reason\":\"max_loop_iterations override exceeds configured limit\",\"configured_max\":$configured_max,\"requested_max\":$MAX}"
  exit 64
}
state_dir=$(dirname "$STATE")
mkdir -p "$state_dir"
lock_file="${STATE}.lock"
lock_dir="${STATE}.lockdir"
lock_mode=""
if command -v flock >/dev/null 2>&1; then
  exec 9>"$lock_file" || exit 1
  flock -x 9 || exit 1
else
  locked=false
  for ((attempt=0; attempt<100; attempt++)); do
    if mkdir "$lock_dir" 2>/dev/null; then locked=true; break; fi
    sleep 0.02
  done
  [[ "$locked" == true ]] || { echo "{\"action\":\"error\",\"reason\":\"loop state lock timeout\"}"; exit 1; }
  lock_mode="mkdir"
fi
tmp=""
cleanup() {
  [[ -z "$tmp" ]] || rm -f "$tmp"
  [[ "$lock_mode" != "mkdir" ]] || rmdir "$lock_dir" 2>/dev/null || true
}
trap cleanup EXIT

it=0; last_hash=""; previous_task=""
if [[ -f "$STATE" ]]; then
  jq -e 'type == "object"
    and (.iterations_used | type == "number" and floor == .)
    and ((.last_attempt_hash // "") | type == "string")
    and ((.task_id // "") | type == "string")' "$STATE" >/dev/null 2>&1 || {
    echo "{\"action\":\"error\",\"reason\":\"invalid loop state\"}"
    exit 1
  }
  it=$(jq -r '.iterations_used' "$STATE")
  last_hash=$(jq -r '.last_attempt_hash // ""' "$STATE")
  previous_task=$(jq -r '.task_id // ""' "$STATE")
  [[ "$it" =~ ^[0-9]+$ ]] && [[ "$last_hash" == "" || "$last_hash" =~ ^[a-fA-F0-9]{64}$ ]] || {
    echo "{\"action\":\"error\",\"reason\":\"invalid loop state values\"}"
    exit 1
  }
fi
if [[ -n "$previous_task" && "$previous_task" != "$task_id" ]]; then
  it=0
  last_hash=""
fi
if [[ -n "$HASH" && -n "$last_hash" && "$HASH" == "$last_hash" ]]; then
  echo "{\"action\":\"force-changed-approach\",\"reason\":\"identical attempt hash: retry must change the approach, not repeat it\",\"hash\":\"$HASH\",\"phase\":\"$PHASE\",\"task\":\"$TASK\"}"
  exit 2
fi
it=$((it + 1))
tmp=$(mktemp "${STATE}.tmp.XXXXXX")
jq -n --arg t "$task_id" --arg p "$PHASE" --arg h "$HASH" --argjson it "$it" --argjson max "$MAX" "{task_id:\$t, last_phase:\$p, last_attempt_hash:\$h, iterations_used:\$it, max_iterations:\$max, updated_at:(now|todateiso8601)}" > "$tmp"
mv "$tmp" "$STATE"
tmp=""
if [[ "$it" -gt "$MAX" ]]; then
  echo "{\"action\":\"BLOCKED\",\"reason\":\"max_loop_iterations exceeded\",\"iterations_used\":$it,\"max_iterations\":$MAX,\"task\":\"$TASK\",\"phase\":\"$PHASE\"}"
  exit 3
fi
echo "{\"action\":\"ok\",\"iterations_used\":$it,\"max_iterations\":$MAX,\"task\":\"$TASK\",\"phase\":\"$PHASE\"}"
exit 0
