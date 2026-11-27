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

# Drift guard: production scoring must load configurable thresholds and retain
# the judge-unavailable cap.
drift=0
grep -q 'scoring.thresholds.pass' "$AUTO_SCORE" || { echo "FAIL drift: configured PASS threshold not loaded"; drift=1; }
grep -q 'scoring.thresholds.retry_min' "$AUTO_SCORE" || { echo "FAIL drift: configured RETRY threshold not loaded"; drift=1; }
grep -q 'tier1_only.*verdict.*PASS' "$AUTO_SCORE" || { echo "FAIL drift: tier1_only never-PASS cap missing"; drift=1; }
grep -q 'permissions_violated' "$AUTO_SCORE" || { echo "FAIL drift: permissions hard-halt missing"; drift=1; }
if grep -q 'status == "deny"' "$AUTO_SCORE"; then
  echo "FAIL drift: denied actions are being treated as completed permission violations"
  drift=1
fi

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
check "denied-attempt-alone" 95 true  false PASS

# A denial in the controller audit must not deduct permission points in the
# production scorer. Compare identical contracts with and without that event.
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
mkdir "$D/denied" "$D/clean"
template="$SCRIPT_DIR/../../contract/contract.template.json"
rules="$SCRIPT_DIR/../../rules/rules.json"
if cp "$template" "$D/denied/contract.json" && cp "$template" "$D/clean/contract.json"; then
  printf '%s\n' '{"op":"pre_tool_action","status":"deny"}' > "$D/denied/workflow-audit.jsonl"
  denied_score=$(bash "$AUTO_SCORE" --file "$D/denied/contract.json" --rules "$rules" --tier 1 --score-only 2>/dev/null)
  clean_score=$(bash "$AUTO_SCORE" --file "$D/clean/contract.json" --rules "$rules" --tier 1 --score-only 2>/dev/null)
  if [[ -n "$denied_score" && "$denied_score" == "$clean_score" ]]; then pass=$((pass+1));
  else fail=$((fail+1)); echo "FAIL denied-but-unexecuted action changed score: $clean_score -> $denied_score"; fi
else
  fail=$((fail+1)); echo "FAIL unable to load production scoring fixtures"
fi

configured_case() {
  local label="$1" pass_threshold="$2" retry_min="$3" expected_rc="$4" rules_file contract output rc
  rules_file="$D/$label-rules.json"
  contract="$D/$label-contract.json"
  jq --argjson pass "$pass_threshold" --argjson retry "$retry_min" \
    '.scoring.thresholds.pass=$pass | .scoring.thresholds.retry_min=$retry' "$rules" > "$rules_file" || return 1
  cp "$template" "$contract" || return 1
  if output=$(bash "$AUTO_SCORE" --file "$contract" --rules "$rules_file" --judge-file "$D/judge.json" --score-only 2>/dev/null); then
    rc=0
  else
    rc=$?
  fi
  output="${output##*$'\n'}"
  if [[ "$output" == "85" && "$rc" == "$expected_rc" ]]; then
    pass=$((pass+1))
  else
    fail=$((fail+1))
    echo "FAIL $label: expected score=85 rc=$expected_rc, got score=$output rc=$rc"
  fi
}
printf '%s\n' '{"score":85,"rationale":"fixture judge","missing_items":[],"model":"fixture"}' > "$D/judge.json"
configured_case "custom-retry-minimum" 95 90 2
configured_case "custom-pass-threshold" 80 60 0

# Tier-1-only scores cannot pass, and the process status reflects that cap.
cp "$template" "$D/tier1-only-contract.json"
if output=$(bash "$AUTO_SCORE" --file "$D/tier1-only-contract.json" --rules "$rules" --tier 1 --score-only 2>/dev/null); then
  rc=0
else
  rc=$?
fi
if [[ "$output" == "85" && "$rc" -eq 1 ]]; then
  pass=$((pass+1))
else
  fail=$((fail+1)); echo "FAIL tier1-only verdict/exit mismatch: score=$output rc=$rc"
fi

invalid_rules="$D/invalid-threshold-rules.json"
jq '.scoring.thresholds.pass=40 | .scoring.thresholds.retry_min=50' "$rules" > "$invalid_rules"
if bash "$AUTO_SCORE" --file "$template" --rules "$invalid_rules" --tier 1 --score-only >/dev/null 2>&1; then
  fail=$((fail+1)); echo "FAIL invalid thresholds were accepted"
else
  pass=$((pass+1))
fi

cat <<EOF
T4 score calibration: $pass passed, $fail failed, false_pass=$false_pass, false_block=$false_block, drift_fail=$drift
EOF
[[ "$fail" -eq 0 && "$drift" -eq 0 ]]
