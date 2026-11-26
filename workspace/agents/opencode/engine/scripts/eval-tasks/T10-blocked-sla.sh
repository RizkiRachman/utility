#!/usr/bin/env bash
# T10-blocked-sla.sh — BLOCKED TTL is configured AND enforced.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$SCRIPT_DIR/../.." && pwd)"
S="$ENGINE/scripts/blocked-sla.sh"
T="$ENGINE/scripts/transition.sh"
RULES="$ENGINE/rules/rules.json"
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
C="$D/contract.json"
cp "$ENGINE/contract/contract.template.json" "$C"
printf '# S\n\n## Current Focus\n\nT\n\n## Known Blockers\n\nN\n' > "$D/state.md"
export CONTRACT_FILE="$C" RULES_FILE="$RULES"
pass=0; fail=0
check_json() { bash "$S" check 2>/dev/null; }
status() { check_json | jq -r '.status'; }
field()  { check_json | jq -r ".$1"; }
ok() { [[ "$2" == "$3" ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $1: expected $3, got $2"; }; }
set_stamp() { jq --arg s "$1" '.retry.blocked_at=$s | .retry.escalation_trace=[]' "$C" > "$C.new" && mv "$C.new" "$C"; }

ok "not blocked" "$(status)" "not_blocked"
ok "ttl from rules" "$(field ttl_hours)" "24"

bash "$T" --to BLOCKED --agent orchestrator --evidence "file:$D/state.md" >/dev/null 2>&1 || { fail=$((fail+1)); echo "FAIL transition to BLOCKED"; }
ok "fresh blocked" "$(status)" "within_sla"
ok "stamp present" "$(jq -r '.retry.blocked_at // "" | if length>0 then "yes" else "no" end' "$C")" "yes"
ok "trace appended" "$(jq '.retry.escalation_trace | length' "$C")" "1"

set_stamp "2026-11-01T00:00:00Z"
ok "old blocked" "$(status)" "sla_breached"
if check_json >/dev/null; then fail=$((fail+1)); echo "FAIL breach exit code"; else pass=$((pass+1)); fi
ok "breach action" "$(field action)" "escalate_to_user_and_scrum_master"

printf '{"state_machine":{"blocked_ttl_hours":1}}' > "$D/rules.json"
custom=$(RULES_FILE="$D/rules.json" bash "$S" check 2>/dev/null | jq -r '.ttl_hours')
ok "custom ttl" "$custom" "1"
RULES_FILE="$RULES" bash "$S" check >/dev/null 2>&1

set_stamp ""
ok "no timestamp" "$(status)" "no_timestamp"
set_stamp "not-a-date"
ok "invalid timestamp" "$(status)" "invalid_timestamp"

# Sweep scans a directory and exits nonzero when any contract breaches.
mkdir -p "$D/sweep"
set_stamp "2026-11-01T00:00:00Z"
cp "$C" "$D/sweep/contract.json"
sweep_out=$(bash "$S" sweep --dir "$D/sweep" 2>/dev/null); sweep_rc=$?
if [[ "$sweep_rc" -eq 1 ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL sweep exit=$sweep_rc"; fi
sweep_status=$(printf '%s\n' "$sweep_out" | jq -r '.status')
ok "sweep status" "$sweep_status" "sla_breached"

# Leaving BLOCKED (with user override) clears the clock.
jq '.governance.user_override=true' "$C" > "$C.new" && mv "$C.new" "$C"
if bash "$T" --to INIT --agent orchestrator --evidence "file:$D/state.md" >/dev/null 2>&1; then
  ok "clock cleared" "$(jq -r '.retry.blocked_at' "$C")" "null"
else fail=$((fail+1)); echo "FAIL transition out of BLOCKED"; fi

echo "T10 blocked SLA: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
