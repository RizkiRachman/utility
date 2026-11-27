#!/usr/bin/env bash
# T19-failure-loop.sh - typed failure-loop strategy selection is exercised.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$SCRIPT_DIR/../.." && pwd)"
S="$ENGINE/scripts/failure-loop.sh"
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
pass=0; fail=0
ok() { [[ "$2" == "$3" ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $1: expected $3, got $2"; }; }
run() { bash "$S" "$@" > "$D/out.json" 2>/dev/null; echo $?; }
run_without_jq() { PATH="$D/no-jq" /bin/bash "$S" "$@" > "$D/out.json" 2>/dev/null; echo $?; }
strategy() { jq -r .strategy "$D/out.json" 2>/dev/null; }

# Deterministic classes change approach immediately; block at the limit.
ok "compile fresh"       "$(run --type compile --attempt 1 --max 3)" "2"
ok "compile strategy"    "$(strategy)" "CHANGE_APPROACH"
ok "compile at limit"    "$(run --type compile --attempt 3 --max 3)" "4"
ok "compile blocked"     "$(strategy)" "BLOCKED"
ok "malformed fresh"     "$(run --type malformed --attempt 1 --max 3)" "2"

# Security always escalates.
ok "security"            "$(run --type security)" "3"
ok "security strategy"   "$(strategy)" "ESCALATE"

# Test failures retry with guidance until evidence or attempts repeat.
ok "test fresh"          "$(run --type test --attempt 1 --max 3)" "0"
ok "test strategy"       "$(strategy)" "RETRY_WITH_GUIDANCE"
ok "test same hash"      "$(run --type test --attempt 1 --max 3 --hash H1 --last-hash H1)" "2"
ok "test at limit"       "$(run --type test --attempt 3 --max 3)" "4"

# Review and gate escalate at the limit.
ok "review fresh"        "$(run --type review --attempt 1 --max 3)" "0"
ok "review same hash"    "$(run --type review --attempt 1 --max 3 --hash R1 --last-hash R1)" "2"
ok "review at limit"     "$(run --type review --attempt 3 --max 3)" "3"
ok "gate at limit"       "$(run --type gate --attempt 2 --max 2)" "3"

# Transient classes retry with backoff, then escalate.
ok "timeout fresh"       "$(run --type timeout --attempt 1 --max 3)" "0"
ok "flaky at limit"      "$(run --type flaky --attempt 3 --max 3)" "3"

# Unknown class still refuses identical evidence and respects the limit.
ok "unknown fresh"       "$(run --type other --attempt 1 --max 3)" "0"
ok "unknown same hash"   "$(run --type other --hash X --last-hash X)" "2"
ok "unknown at limit"    "$(run --type other --attempt 3 --max 3)" "4"
ok "quoted task context" "$(run --type test --task 'task"with quote')" "0"
jq -e '.task == "task\"with quote"' "$D/out.json" >/dev/null 2>&1 && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL task context was not safely JSON encoded"; }

# Malformed invocation is rejected.
ok "missing type"        "$(run)" "5"
ok "unknown arg"         "$(run --type test --bogus 1)" "5"
ok "missing attempt value" "$(run --type test --attempt)" "5"
ok "non-numeric attempt" "$(run --type test --attempt nope --max 3)" "5"
ok "zero attempt"        "$(run --type test --attempt 0 --max 3)" "5"
ok "zero max"            "$(run --type test --attempt 1 --max 0)" "5"
ok "oversized attempt"   "$(run --type test --attempt 9999999999999999 --max 3)" "5"
mkdir "$D/no-jq"
ok "missing jq"          "$(run_without_jq --type test)" "5"

echo "T19 failure loop: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
