#!/usr/bin/env bash
# scripts/checkpoint.sh - C4: orchestrator checkpoint protocol.
# Emits a directive; runs before each delegation.
# Exit codes: 0 ok | 1 warn | 2 critical
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CONTRACT="session/contract.json"
DELIG=""
MAXDEL=20
while [[ $# -gt 0 ]]; do
  case "$1" in
    --contract) CONTRACT="$2"; shift 2 ;;
    --delegations) DELIG="$2"; shift 2 ;;
    --max-delegations) MAXDEL="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done
[[ -f "$CONTRACT" ]] || { echo "contract not found" >&2; exit 64; }
used=$(jq -r ".token_budget.current_session_usage // 0" "$CONTRACT")
total=$(jq -r ".token_budget.max_per_session // 200000" "$CONTRACT")
warn_r=$(jq -r ".token_budget.warning_threshold // 0.8" "$CONTRACT")
hard_r=$(jq -r ".token_budget.hard_limit // 0.95" "$CONTRACT")
delig=${DELIG:-$(jq -r ".governance.delegations_used // 0" "$CONTRACT")}
ratio=$(awk -v u="$used" -v t="$total" 'BEGIN{ printf "%.3f", u/t }')
cmp=$(awk -v r="$ratio" -v w="$warn_r" -v h="$hard_r" 'BEGIN{ if (r+0 >= h+0) print 2; else if (r+0 >= w+0) print 1; else print 0 }')
if [[ "$delig" =~ ^[0-9]+$ ]]; then
  if (( delig >= MAXDEL )); then cmp=1; fi
fi
A="context-reset-required"
D="persist envelope, snapshot, then hand off. A fresh session resumes from session/contract.json alone."
if [[ "$cmp" == "2" ]]; then
  jq -n --arg action "$A" --argjson ratio "$ratio" --argjson used "$used" --argjson delegations "$delig" --arg d "$D" '{action:$action, ratio:$ratio, used:$used, delegations:$delegations, directive:$d}'
  exit 2
fi
A="save-session-protocol"
D="run the Save Session Protocol now: persist, snapshot, archive, then hand off to a fresh session."
if [[ "$cmp" == "1" ]]; then
  jq -n --arg action "$A" --argjson ratio "$ratio" --argjson delegations "$delig" --arg d "$D" '{action:$action, ratio:$ratio, delegations:$delegations, directive:$d}'
  exit 1
fi
jq -n --arg action "ok" --argjson ratio "$ratio" --argjson used "$used" --argjson delegations "$delig" '{action:$action, ratio:$ratio, used:$used, delegations:$delegations}'
exit 0
