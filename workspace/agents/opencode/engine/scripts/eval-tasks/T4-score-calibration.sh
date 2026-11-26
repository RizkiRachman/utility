#!/usr/bin/env bash
# T4-score-calibration.sh — deterministic verdict corpus with drift detection.
# Mirrors auto-score.sh compute_verdict + the tier1_only "never PASS" cap and
# checks the mirror still matches the thresholds in auto-score.sh source.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_SCORE="$(cd "$SCRIPT_DIR/.." && pwd)/auto-score.sh"

verdict_of() {
  local score="$1" judge="$2" perms="${3:-false}" v
  if [[ "$perms" == true ]]; then echo "BLOCKED"; return; fi
  if   [[ "$score" -ge 70 ]]; then v="PASS"
  elif [[ "$score" -ge 50 ]]; then v="RETRY"
  else v="BLOCKED"; fi
  [[ "$judge" == false && "$v" == PASS ]] && v="RETRY"
  echo "$v"
}

# Drift guard: if auto-score.sh thresholds or the cap change, this task fails
# even if all corpus expectations still pass.
drift=0
grep -q 'combined -ge 70' "$AUTO_SCORE" || { echo "FAIL drift: PASS threshold != 70 in auto-score.sh"; drift=1; }
grep -q 'combined -ge 50' "$AUTO_SCORE" || { echo "FAIL drift: RETRY threshold != 50 in auto-score.sh"; drift=1; }
grep -q 'judge_unavailable.*PASS' "$AUTO_SCORE" || { echo "FAIL drift: tier1_only never-PASS cap missing"; drift=1; }
grep -q 'permissions_violated' "$AUTO_SCORE" || { echo "FAIL drift: permissions hard-halt missing"; drift=1; }

pass=0; fail=0; false_pass=0; false_block=0
check() {
  local name="$1" score="$2" judge="$3" perms="$4" expected="$5"
  local got; got=$(verdict_of "$score" "$judge" "$perms")
  if [[ "$got" == "$expected" ]]; then pass=$((pass+1));
  else
    fail=$((fail+1))
    [[ "$expected" != PASS && "$got" == PASS ]] && false_pass=$((false_pass+1))
    [[ "$expected" == PASS && "$got" == BLOCKED ]] && false_block=$((false_block+1))
    echo "FAIL $name: expected $expected, got $got"
  fi
}
check "pass-with-judge"      85 true  false PASS
check "pass-without-judge"   85 false false RETRY
check "retry-band"           60 true  false RETRY
check "block-band"           45 true  false BLOCKED
check "boundary-pass-70"     70 true  false PASS
check "boundary-retry-69"    69 true  false RETRY
check "boundary-retry-50"    50 true  false RETRY
check "boundary-block-49"    49 true  false BLOCKED
check "perfect-score"       100 false false RETRY
check "zero-score"            0 true  false BLOCKED
check "permissions-halt"     95 true  true  BLOCKED

cat <<EOF
T4 score calibration: $pass passed, $fail failed, false_pass=$false_pass, false_block=$false_block, drift_fail=$drift
EOF
[[ "$fail" -eq 0 && "$drift" -eq 0 ]]
