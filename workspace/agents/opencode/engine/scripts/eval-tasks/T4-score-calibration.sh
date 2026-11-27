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

# Value-taking options must fail deterministically when their value is absent.
for missing_option in --file --rules --tier --phase --judge-file; do
  if output=$(bash "$AUTO_SCORE" "$missing_option" 2>/dev/null); then
    rc=0
  else
    rc=$?
  fi
  if [[ "$rc" -eq 2 && -z "$output" ]]; then
    pass=$((pass+1))
  else
    fail=$((fail+1)); echo "FAIL missing value for $missing_option: rc=$rc output='$output'"
  fi
done
if output=$(bash "$AUTO_SCORE" --file "" 2>/dev/null); then
  rc=0
else
  rc=$?
fi
if [[ "$rc" -eq 2 && -z "$output" ]]; then
  pass=$((pass+1))
else
  fail=$((fail+1)); echo "FAIL empty --file value was not rejected (rc=$rc)"
fi
if output=$(bash "$AUTO_SCORE" --unknown-option 2>/dev/null); then
  rc=0
else
  rc=$?
fi
if [[ "$rc" -eq 2 && -z "$output" ]]; then
  pass=$((pass+1))
else
  fail=$((fail+1)); echo "FAIL unknown option was not rejected (rc=$rc)"
fi
if bash "$AUTO_SCORE" --help >/dev/null 2>&1; then
  pass=$((pass+1))
else
  fail=$((fail+1)); echo "FAIL --help did not exit successfully"
fi

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
printf '%s\n' '{"score":85,"rationale":"fixture|judge\nsecond line","missing_items":["edge case"],"model":"fixture"}' > "$D/judge.json"
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

# Explicit score phases must exist in the configured scored-state transitions.
mkdir "$D/valid-phase" "$D/invalid-phase"
cp "$template" "$D/valid-phase/contract.json"
if output=$(bash "$AUTO_SCORE" --file "$D/valid-phase/contract.json" --rules "$rules" --tier 1 --phase PLAN --score-only 2>/dev/null); then
  rc=0
else
  rc=$?
fi
if [[ "$output" == "85" && "$rc" -eq 1 ]] &&
  jq -se 'length == 1 and .[0].phase == "PLAN"' "$D/valid-phase/scores.jsonl" >/dev/null 2>&1; then
  pass=$((pass+1))
else
  fail=$((fail+1)); echo "FAIL configured score phase was rejected or not recorded (rc=$rc)"
fi
cp "$template" "$D/invalid-phase/contract.json"
if output=$(bash "$AUTO_SCORE" --file "$D/invalid-phase/contract.json" --rules "$rules" --tier 1 --phase NOT_A_PHASE --score-only 2>/dev/null); then
  rc=0
else
  rc=$?
fi
if [[ "$rc" -eq 2 && -z "$output" && ! -e "$D/invalid-phase/scores.jsonl" ]]; then
  pass=$((pass+1))
else
  fail=$((fail+1)); echo "FAIL unconfigured phase emitted score/evidence (rc=$rc)"
fi

# Full output remains machine-readable JSON, without progress text on stdout.
cp "$template" "$D/full-json-contract.json"
printf '%s\n' '{"score":40,"rationale":"judge unavailable for unrelated criteria","missing_items":[],"model":"fixture"}' > "$D/judge.json"
if output=$(bash "$AUTO_SCORE" --file "$D/full-json-contract.json" --rules "$rules" --judge-file "$D/judge.json" 2>/dev/null); then
  rc=0
else
  rc=$?
fi
if [[ "$rc" -eq 1 ]] && printf '%s\n' "$output" | jq -e '
  .score.combined == 63
  and .score.verdict == "RETRY"
  and .score.tier1_only == false
  and .score.judge.rationale == "judge unavailable for unrelated criteria"
' >/dev/null 2>&1; then
  pass=$((pass+1))
else
  fail=$((fail+1)); echo "FAIL judge rationale changed verdict or output was not machine-readable (rc=$rc)"
fi

# Structured judge results preserve delimiters and newlines in all fields.
mkdir "$D/judge-text"
cp "$template" "$D/judge-text/contract.json"
printf '%s\n' '{"score":85,"rationale":"fixture|judge\nsecond line","missing_items":["edge|case","line\nbreak"],"model":"fixture|model"}' > "$D/judge-text/judge.json"
if output=$(bash "$AUTO_SCORE" --file "$D/judge-text/contract.json" --rules "$rules" --judge-file "$D/judge-text/judge.json" 2>/dev/null); then
  rc=0
else
  rc=$?
fi
if [[ "$rc" -eq 0 ]] && printf '%s\n' "$output" | jq -e '
  .score.combined == 85
  and .score.verdict == "PASS"
  and .score.judge.rationale == "fixture|judge\nsecond line"
  and .score.judge.missing_items == ["edge|case", "line\nbreak"]
  and .score.judge.model == "fixture|model"
' >/dev/null 2>&1; then
  pass=$((pass+1))
else
  fail=$((fail+1)); echo "FAIL structured judge fields did not round-trip (rc=$rc)"
fi

# Judge-unavailable fallback also crosses the internal boundary as structured JSON.
cp "$template" "$D/unavailable-judge-contract.json"
if output=$(bash "$AUTO_SCORE" --file "$D/unavailable-judge-contract.json" --rules "$rules" 2>/dev/null); then
  rc=0
else
  rc=$?
fi
if [[ "$rc" -eq 1 ]] && printf '%s\n' "$output" | jq -e '
  .score.combined == 85
  and .score.judge.score == 85
  and .score.tier1_only == true
  and .score.verdict == "RETRY"
  and (.score.judge.rationale | contains("unavailable"))
' >/dev/null 2>&1; then
  pass=$((pass+1))
else
  fail=$((fail+1)); echo "FAIL judge-unavailable fallback output contract (rc=$rc)"
fi

# Optional judge fields may be omitted and receive their documented defaults.
mkdir "$D/judge-minimal"
cp "$template" "$D/judge-minimal/contract.json"
printf '%s\n' '{"score":85}' > "$D/judge-minimal/judge.json"
if output=$(bash "$AUTO_SCORE" --file "$D/judge-minimal/contract.json" --rules "$rules" --judge-file "$D/judge-minimal/judge.json" 2>/dev/null); then
  rc=0
else
  rc=$?
fi
if [[ "$rc" -eq 0 ]] && printf '%s\n' "$output" | jq -e '.score.judge.rationale | startswith("external judge artifact")' >/dev/null 2>&1 &&
  printf '%s\n' "$output" | jq -e '.score.judge.missing_items == [] and .score.judge.model == ""' >/dev/null 2>&1; then
  pass=$((pass+1))
else
  fail=$((fail+1)); echo "FAIL omitted optional judge fields were not defaulted safely (rc=$rc)"
fi

# Explicitly supplied malformed judge data fails before emitting score/ledger evidence.
mkdir "$D/invalid-judge"
for invalid_judge in \
  '{"score":"85"}' \
  '{"score":85,"rationale":[]}' \
  '{"score":85,"missing_items":"none"}' \
  '{"score":85,"model":42}'; do
  printf '%s\n' "$invalid_judge" > "$D/invalid-judge/judge.json"
  cp "$template" "$D/invalid-judge/contract.json"
  if output=$(bash "$AUTO_SCORE" --file "$D/invalid-judge/contract.json" --rules "$rules" --judge-file "$D/invalid-judge/judge.json" --score-only 2>/dev/null); then
    rc=0
  else
    rc=$?
  fi
  if [[ "$rc" -eq 2 && -z "$output" && ! -e "$D/invalid-judge/scores.jsonl" ]]; then
    pass=$((pass+1))
  else
    fail=$((fail+1)); echo "FAIL malformed judge artifact emitted score/evidence (rc=$rc, output='$output')"
  fi
done

# Tier 1 mode cannot consume a judge file and must not silently ignore it.
mkdir "$D/tier1-with-judge"
cp "$template" "$D/tier1-with-judge/contract.json"
if output=$(bash "$AUTO_SCORE" --file "$D/tier1-with-judge/contract.json" --rules "$rules" --tier 1 --judge-file "$D/judge.json" --score-only 2>/dev/null); then
  rc=0
else
  rc=$?
fi
if [[ "$rc" -eq 2 && -z "$output" && ! -e "$D/tier1-with-judge/scores.jsonl" ]]; then
  pass=$((pass+1))
else
  fail=$((fail+1)); echo "FAIL tier 1 silently ignored --judge-file (rc=$rc)"
fi

# Tier 2 is prompt export only, not a score; it must not create a ledger row.
mkdir "$D/judge-prompt"
jq '.requirements.goal="preserve goal | with separators" | .requirements.acceptance_criteria=["first; criterion", "second\ncriterion"] | .requirements.constraints=["no external network; preserve API", "constraint\nwith newline"]' \
  "$template" > "$D/judge-prompt/contract.json"
if output=$(bash "$AUTO_SCORE" --file "$D/judge-prompt/contract.json" --rules "$rules" --tier 2 2>/dev/null); then
  rc=0
else
  rc=$?
fi
if [[ "$rc" -eq 0 ]] && printf '%s\n' "$output" | jq -e '
  (.judge_prompt | type == "string")
  and .contract.requirements.goal == "preserve goal | with separators"
  and .contract.requirements.acceptance_criteria == ["first; criterion", "second\ncriterion"]
  and .contract.requirements.constraints == ["no external network; preserve API", "constraint\nwith newline"]
' >/dev/null 2>&1 &&
  [[ ! -e "$D/judge-prompt/scores.jsonl" ]]; then
  pass=$((pass+1))
else
  fail=$((fail+1)); echo "FAIL tier 2 did not honor prompt-only output contract (rc=$rc)"
fi

# Supplying a judge result to prompt-export mode must fail rather than ignore it.
if output=$(bash "$AUTO_SCORE" --file "$D/judge-prompt/contract.json" --rules "$rules" --tier 2 --judge-file "$D/judge.json" 2>/dev/null); then
  rc=0
else
  rc=$?
fi
if [[ "$rc" -eq 2 && -z "$output" && ! -e "$D/judge-prompt/scores.jsonl" ]]; then
  pass=$((pass+1))
else
  fail=$((fail+1)); echo "FAIL tier 2 silently accepted --judge-file (rc=$rc)"
fi
for incompatible in score-only phase; do
  if [[ "$incompatible" == "score-only" ]]; then
    args=(--score-only)
  else
    args=(--phase PLAN)
  fi
  if output=$(bash "$AUTO_SCORE" --file "$D/judge-prompt/contract.json" --rules "$rules" --tier 2 "${args[@]}" 2>/dev/null); then
    rc=0
  else
    rc=$?
  fi
  if [[ "$rc" -eq 2 && -z "$output" && ! -e "$D/judge-prompt/scores.jsonl" ]]; then
    pass=$((pass+1))
  else
    fail=$((fail+1)); echo "FAIL tier 2 silently accepted --$incompatible (rc=$rc)"
  fi
done

# A score is not reported as usable if its mandatory ledger cannot be persisted.
mkdir "$D/ledger-failure" && cp "$template" "$D/ledger-failure/contract.json"
mkdir "$D/ledger-failure/scores.jsonl"
if output=$(bash "$AUTO_SCORE" --file "$D/ledger-failure/contract.json" --rules "$rules" --tier 1 --score-only 2>/dev/null); then
  rc=0
else
  rc=$?
fi
if [[ -z "$output" && "$rc" -eq 2 ]]; then
  pass=$((pass+1))
else
  fail=$((fail+1)); echo "FAIL score emitted without ledger persistence: score=$output rc=$rc"
fi
cp "$template" "$D/ledger-failure/full-output-contract.json"
if output=$(bash "$AUTO_SCORE" --file "$D/ledger-failure/full-output-contract.json" --rules "$rules" --tier 1 2>/dev/null); then
  rc=0
else
  rc=$?
fi
if [[ -z "$output" && "$rc" -eq 2 ]]; then
  pass=$((pass+1))
else
  fail=$((fail+1)); echo "FAIL full score emitted without ledger persistence: output='$output' rc=$rc"
fi

# --score-only must keep diagnostics off stdout even when Tier 2 is skipped.
jq '.governance.permissions_violated=true' "$template" > "$D/low-score-contract.json"
if output=$(bash "$AUTO_SCORE" --file "$D/low-score-contract.json" --rules "$rules" --tier 1 --score-only 2>/dev/null); then
  rc=0
else
  rc=$?
fi
if [[ "$output" == "0" && "$rc" -eq 2 ]]; then
  pass=$((pass+1))
else
  fail=$((fail+1)); echo "FAIL --score-only output contract: expected numeric score only, got '$output' rc=$rc"
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
