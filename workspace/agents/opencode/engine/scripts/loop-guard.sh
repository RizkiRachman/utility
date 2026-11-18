#!/usr/bin/env bash
# scripts/loop-guard.sh - C3: controller-enforced loop iteration cap + changed-
# approach retry hash. The CONTROLLER runs this (orchestrator, before each
# delegation and after every *_SCORED verdict); agents never self-exempt.
# Deterministic, file-based (session/loop-state.json), no daemon.
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
if [[ -z "$MAX" ]]; then
  RULES="${RULES_PATH:-$(dirname "$SCRIPT_DIR")/../rules/rules.json}"
  MAX=$(jq -r ".enforcement.loop_guard.max_loop_iterations // 12" "$RULES" 2>/dev/null || echo 12)
fi
it=0; last_hash=""
if [[ -f "$STATE" ]]; then
  it=$(jq -r ".iterations_used // 0" "$STATE" 2>/dev/null || echo 0)
  last_hash=$(jq -r ".last_attempt_hash // \"\"" "$STATE" 2>/dev/null || echo "")
fi
if [[ -n "$HASH" && -n "$last_hash" && "$HASH" == "$last_hash" ]]; then
  echo "{\"action\":\"force-changed-approach\",\"reason\":\"identical attempt hash: retry must change the approach, not repeat it\",\"hash\":\"$HASH\",\"phase\":\"$PHASE\",\"task\":\"$TASK\"}"
  exit 2
fi
it=$((it + 1))
tmp=$(mktemp)
jq -n --arg t "${TASK:-$(jq -r ".session.task_id // \"unknown\"" "$CONTRACT" 2>/dev/null || echo unknown)}" --arg p "$PHASE" --arg h "$HASH" --argjson it "$it" --argjson max "$MAX" "{task_id:\$t, last_phase:\$p, last_attempt_hash:\$h, iterations_used:\$it, max_iterations:\$max, updated_at:(now|todateiso8601)}" > "$tmp"
mkdir -p "$(dirname "$STATE")"
mv "$tmp" "$STATE"
if [[ "$it" -gt "$MAX" ]]; then
  echo "{\"action\":\"BLOCKED\",\"reason\":\"max_loop_iterations exceeded\",\"iterations_used\":$it,\"max_iterations\":$MAX,\"task\":\"$TASK\",\"phase\":\"$PHASE\"}"
  exit 3
fi
echo "{\"action\":\"ok\",\"iterations_used\":$it,\"max_iterations\":$MAX,\"task\":\"$TASK\",\"phase\":\"$PHASE\"}"
exit 0
