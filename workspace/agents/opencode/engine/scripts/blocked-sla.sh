#!/usr/bin/env bash
# blocked-sla.sh — enforce the BLOCKED-state TTL declared in rules.json.
# `check` reports one contract's SLA status (exit 1 when breached).
# `sweep` scans a directory of contract.json files for breaches.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACT="${CONTRACT_FILE:-session/contract.json}"
RULES="${RULES_FILE:-$SCRIPT_DIR/../rules/rules.json}"
OP="${1:-}"; [[ $# -gt 0 ]] && shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --contract) CONTRACT="$2"; shift 2 ;; --rules) RULES="$2"; shift 2 ;;
    --dir) DIR="$2"; shift 2 ;;
    *) echo "blocked-sla.sh: unknown arg $1" >&2; exit 2 ;;
  esac
done

ttl_hours() {
  local t
  t=$(jq -r '.state_machine.blocked_ttl_hours // 24' "$RULES" 2>/dev/null) || t=24
  [[ "$t" =~ ^[0-9]+$ ]] || t=24
  echo "$t"
}

blocked_stamp() {
  jq -r '
    ([.retry.escalation_trace[]? | select(.blocked_at != null and .blocked_at != "") | .blocked_at] | .[-1] // null) as $last
    | if ($last // "") != "" then $last else (.retry.blocked_at // "") end
  ' "$CONTRACT" 2>/dev/null || echo ""
}

check_one() {
  local c="$1" state stamp age ttl status action now b_epoch
  CONTRACT="$c"
  [[ -f "$CONTRACT" ]] || { echo "blocked-sla: contract not found: $CONTRACT" >&2; return 2; }
  ttl=$(ttl_hours)
  state=$(jq -r '.state // "INIT"' "$CONTRACT" 2>/dev/null)
  if [[ "$state" != "BLOCKED" ]]; then
    jq -cn --arg s "$state" --argjson t "$ttl" \
      '{contract:$c_path,state:$s,status:"not_blocked",ttl_hours:$t,age_hours:0,blocked_at:null,action:"none"}' \
      --arg c_path "$CONTRACT" 2>/dev/null
    return 0
  fi
  stamp=$(blocked_stamp)
  if [[ -z "$stamp" ]]; then
    jq -cn --arg c "$CONTRACT" --argjson t "$ttl" \
      '{contract:$c,state:"BLOCKED",status:"no_timestamp",ttl_hours:$t,age_hours:null,blocked_at:null,action:"stamp_retry.blocked_at_on_transition"}' 2>/dev/null
    return 0
  fi
  b_epoch=$(python3 - "$stamp" <<'PY' 2>/dev/null
import datetime, sys
s = sys.argv[1]
try:
    d = datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    print(int(d.timestamp()))
except Exception:
    pass
PY
  )
  if [[ -z "$b_epoch" ]]; then
    jq -cn --arg c "$CONTRACT" --argjson t "$ttl" --arg s "$stamp" \
      '{contract:$c,state:"BLOCKED",status:"invalid_timestamp",ttl_hours:$t,age_hours:null,blocked_at:$s,action:"fix_blocked_at"}' 2>/dev/null
    return 0
  fi
  now=$(date -u +%s)
  age=$(( (now - b_epoch) / 3600 ))
  if [[ "$age" -lt 0 ]]; then age=0; fi
  if [[ "$age" -ge "$ttl" ]]; then
    status="sla_breached"; action="escalate_to_user_and_scrum_master"
  else
    status="within_sla"; action="wait_for_user_override"
  fi
  jq -cn --arg c "$CONTRACT" --argjson t "$ttl" --arg st "$status" --arg a "$action" \
    --argjson age "$age" --arg b "$stamp" \
    '{contract:$c,state:"BLOCKED",status:$st,ttl_hours:$t,age_hours:$age,blocked_at:$b,action:$a}' 2>/dev/null
  [[ "$status" == "sla_breached" ]] && return 1 || return 0
}

case "$OP" in
  check) check_one "$CONTRACT" | jq -c '. + {mode:"operator_driven"}' ;;
  sweep)
    [[ -n "${DIR:-}" && -d "$DIR" ]] || { echo "usage: blocked-sla.sh sweep --dir DIR" >&2; exit 2; }
    rc=0
    while IFS= read -r c; do
      check_one "$c" | jq -c '. + {mode:"operator_driven"}' || rc=1
    done < <(find "$DIR" -name contract.json -type f 2>/dev/null | sort)
    exit "$rc" ;;
  *) echo "usage: blocked-sla.sh {check|sweep} [--contract PATH] [--rules PATH] [--dir DIR]" >&2; exit 2 ;;
esac
