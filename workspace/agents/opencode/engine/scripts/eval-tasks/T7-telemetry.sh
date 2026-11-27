#!/usr/bin/env bash
# T7-telemetry.sh — per-phase telemetry reports must ignore incomplete runs.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$SCRIPT_DIR/../phase-telemetry.sh"
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
export TELEMETRY_LOG="$D/tel.jsonl"
printf '{"state":"INIT","session":{"task_id":"t7","task_class":"standard"}}' > "$D/contract.json"
export CONTRACT_FILE="$D/contract.json"
pass=0; fail=0
check() {
  local label="$1" expr="$2" want="$3" got
  got=$(bash "$S" report 2>/dev/null | jq -r "$expr")
  if [[ "$got" == "$want" ]]; then pass=$((pass+1));
  else fail=$((fail+1)); echo "FAIL $label: $expr expected $want, got $got"; fi
}
check "empty report" ".runs" "0"
r=$(bash "$S" start --phase PLAN)
[[ -n "$r" ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL start returned run id"; }
check "orphan excluded" ".runs" "0"
[[ "$(bash "$S" active | jq -r 'length')" == "1" ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL active orphan"; }
bash "$S" stop --run-id "$r" --tokens-in 900 --tokens-out 300 --verdict PASS >/dev/null || { fail=$((fail+1)); echo "FAIL stop"; }
check "completed run" ".runs" "1"
check "tokens in" ".tokens_in" "900"
check "tokens out" ".tokens_out" "300"
check "phase from start" ".by_phase.PLAN" "1"
check "class from contract" '.by_class.standard' "1"
if bash "$S" stop --run-id "$r" --tokens-in -1 >/dev/null 2>&1; then
  fail=$((fail+1)); echo "FAIL negative token count accepted"
else pass=$((pass+1)); fi
jq -cn --arg r "$r" '{event:"stop",run_id:$r,elapsed_ms:999,tokens_in:9000,tokens_out:9000}' >> "$TELEMETRY_LOG"
jq -cn '{event:"stop",run_id:"orphan-stop",elapsed_ms:1000,tokens_in:1,tokens_out:1}' >> "$TELEMETRY_LOG"
jq -cn '{event:"start",run_id:"invalid-stop",phase:"REVIEW",task_class:"standard",task_id:"t7"}' >> "$TELEMETRY_LOG"
jq -cn '{event:"stop",run_id:"invalid-stop",elapsed_ms:"invalid",tokens_in:1,tokens_out:1}' >> "$TELEMETRY_LOG"
jq -cn '{event:"stop",run_id:"invalid-stop",elapsed_ms:1000,tokens_in:-1,tokens_out:1}' >> "$TELEMETRY_LOG"
check "duplicate orphan and malformed stops excluded" ".runs" "1"
check "duplicate tokens excluded" ".tokens_in" "900"
[[ "$(bash "$S" active | jq -r 'length')" == "1" ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL malformed stop closed an active run"; }
if bash "$S" coverage --class standard --task t7 --phases PLAN,REVIEW > "$D/coverage.json"; then
  rc=0
else
  rc=$?
fi
if [[ "$rc" -eq 1 ]] && jq -e '.covered == ["PLAN"] and .missing == ["REVIEW"]' "$D/coverage.json" >/dev/null 2>&1; then
  pass=$((pass+1))
else
  fail=$((fail+1)); echo "FAIL malformed stop counted toward phase coverage"
fi
printf '{bad json\n' >> "$TELEMETRY_LOG"
check "malformed ignored" ".runs" "1"
check "active empty" ".runs" "1"
if bash "$S" stop --run-id does-not-exist >/dev/null 2>&1; then
  fail=$((fail+1)); echo "FAIL unknown run should be denied"
else pass=$((pass+1)); fi
echo "T7 telemetry: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
