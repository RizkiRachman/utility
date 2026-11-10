#!/usr/bin/env bash
# test-transitions.sh - transition-gate regression tests (R3-01b).
#
# Pins the BLOCKED escalation predicate in validate-contract.sh:
#   edge score_lt: 50, or_retry_exhausted: true (rules.json wildcard edge).
#
#   1. score 49, attempts < max   -> BLOCKED edge legal (score below threshold)
#   2. score 60, attempts >= max  -> BLOCKED edge legal (retry exhausted)
#   3. score 60, attempts < max   -> BLOCKED edge illegal (RETRY path only)
#
# validate-contract.sh exposes no single-transition CLI, so each case drives
# the real script with a fixture contract and asserts the escalation verdict
# line emitted by check_score_gate.
# Exit codes: 0 = all three assertions pass, 1 = assertion failure.
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
VALIDATE="${SCRIPT_DIR}/../validate-contract.sh"
WORK_DIR="${TMPDIR:-/tmp}/opencode/r3-transitions"
PASS=0
FAIL=0

if [[ ! -f "$VALIDATE" ]]; then
    echo "FATAL: validate-contract.sh not found at $VALIDATE" >&2
    exit 1
fi

mkdir -p "$WORK_DIR"

# fixture_files CASE SCORE ATTEMPT MAX -> writes $WORK_DIR/case-N.json
fixture() {
    local case_id="$1" score="$2" attempt="$3" max_attempts="$4"
    jq -n \
        --argjson score "$score" \
        --argjson attempt "$attempt" \
        --argjson max_attempts "$max_attempts" \
        '{state: "PLAN_SCORED",
          governance: {target_state: "BLOCKED", user_override: false},
          score: {combined: $score},
          retry: {attempt: $attempt, max_attempts: $max_attempts}}' \
        > "${WORK_DIR}/${case_id}.json"
}

# run_gate CASE_ID -> escalation output lines (stderr + stdout merged)
run_gate() {
    bash "$VALIDATE" --file "${WORK_DIR}/$1.json" --score 2>&1 | grep -i "escalation gate" || true
}

# expect CASE_ID LABEL PATTERN -> PASS when PATTERN is present
expect() {
    local case_id="$1" label="$2" pattern="$3"
    local output
    output="$(run_gate "$case_id")"
    if printf '%s\n' "$output" | grep -q "$pattern"; then
        echo "PASS: ${case_id} - ${label}"
        PASS=$((PASS + 1))
    else
        echo "FAIL: ${case_id} - ${label} (pattern not found: ${pattern})"
        echo "  observed: ${output:-<none>}"
        FAIL=$((FAIL + 1))
    fi
}

# expect_absent CASE_ID LABEL PATTERN -> PASS when PATTERN is absent
expect_absent() {
    local case_id="$1" label="$2" pattern="$3"
    local output
    output="$(run_gate "$case_id")"
    if printf '%s\n' "$output" | grep -q "$pattern"; then
        echo "FAIL: ${case_id} - ${label} (pattern unexpectedly present: ${pattern})"
        echo "  observed: ${output:-<none>}"
        FAIL=$((FAIL + 1))
    else
        echo "PASS: ${case_id} - ${label}"
        PASS=$((PASS + 1))
    fi
}

echo "== Transition gate tests (validate-contract.sh escalation predicate) =="

# Case 1: score 49, retries left -> below score_lt, escalation legal.
fixture case-1 49 1 3
expect case-1 "score 49 < 50 escalates with retries left" "score 49 < 50"

# Case 2: score 60, retries exhausted -> legal even above score_lt (R3-01).
fixture case-2 60 3 3
expect case-2 "score 60 escalates when retry exhausted" "retry exhausted"
expect_absent case-2 "score 60 escalation is not score-gated when exhausted" "requires score < 50"

# Case 3: score 60, retries left -> escalation illegal (RETRY path only).
fixture case-3 60 1 3
expect case-3 "score 60 blocked while retries remain" "requires score < 50"

echo "------------------------------------------"
echo "Results: ${PASS} passed, ${FAIL} failed"
echo "------------------------------------------"

[[ "$FAIL" -eq 0 ]] && exit 0
exit 1
