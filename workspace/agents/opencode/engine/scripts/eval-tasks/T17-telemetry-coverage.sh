#!/usr/bin/env bash
# T17-telemetry-coverage.sh — phase telemetry coverage is checked per task class.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$SCRIPT_DIR/../.." && pwd)"
S="$ENGINE/scripts/phase-telemetry.sh"
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
export TELEMETRY_LOG="$D/tel.jsonl"
pass=0; fail=0
ok() { [[ "$2" == "$3" ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $1: expected $3, got $2"; }; }
finish() { local r; r=$($S start --phase "$1" --class "$2" --task "$3"); $S stop --run-id "$r" >/dev/null 2>&1; }
cov() { $S coverage --class "$1" --task "$2" "${@:3}" 2>/dev/null; }

# Two of three standard phases -> incomplete, missing REVIEW.
finish PLAN standard t1; finish EXECUTE standard t1
cov standard t1 > "$D/c1.json"; rc=$?
ok "incomplete exit" "$rc" "1"
ok "incomplete status" "$(jq -r .status "$D/c1.json")" "incomplete"
ok "missing phase" "$(jq -r '.missing[0]' "$D/c1.json")" "REVIEW"

# Third phase completes coverage.
finish REVIEW standard t1
cov standard t1 > "$D/c2.json"; rc=$?
ok "complete exit" "$rc" "0"
ok "complete status" "$(jq -r .status "$D/c2.json")" "complete"
ok "covered count" "$(jq -r '.covered|length' "$D/c2.json")" "3"

# An orphan start (no stop) never counts as completed.
$S start --phase REVIEW --class standard --task t2 >/dev/null
cov standard t2 > "$D/c3.json"; rc=$?
ok "orphan not covered" "$rc" "1"

# Light classes require only EXECUTE.
finish EXECUTE trivial t3
cov trivial t3 > "$D/c4.json"; rc=$?
ok "trivial complete" "$rc" "0"
ok "trivial expected" "$(jq -r '.expected|length' "$D/c4.json")" "1"

# Explicit phase override narrows the gate.
cov standard t1 --phases PLAN > "$D/c5.json"; rc=$?
ok "override complete" "$rc" "0"
ok "override expected" "$(jq -r '.expected[0]' "$D/c5.json")" "PLAN"

echo "T17 telemetry coverage: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
