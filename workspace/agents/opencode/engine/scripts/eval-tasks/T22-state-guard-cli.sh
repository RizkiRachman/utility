#!/usr/bin/env bash
# T22-state-guard-cli.sh — state-guard rejects malformed CLI input predictably.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$SCRIPT_DIR/../.." && pwd)"
GUARD="$ENGINE/scripts/state-guard.sh"
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
pass=0
fail=0

expect_error() {
  local label="$1" expected="$2" output rc
  shift 2
  if output=$("$@" 2>&1); then
    fail=$((fail+1)); echo "FAIL $label: unexpected success"
    return
  else
    rc=$?
  fi
  if [[ "$rc" -eq 2 ]] && grep -Fq -- "$expected" <<< "$output"; then
    pass=$((pass+1))
  else
    fail=$((fail+1)); echo "FAIL $label: expected exit 2 and '$expected', got $rc: $output"
  fi
}

for option in --agent --contract --contract-dir --state --blast-radius --to; do
  expect_error "$option missing value" "$option requires a value" bash "$GUARD" "$option"
done
expect_error "option-shaped value" "--agent requires a value" bash "$GUARD" --agent --state PLAN
expect_error "empty value" "--agent requires a value" bash "$GUARD" --agent ""
expect_error "unknown option" "Unknown option: --unknown" bash "$GUARD" --agent developer --state EXECUTE --unknown
expect_error "invalid blast radius" "must be HIGH or CRITICAL" bash "$GUARD" --agent developer --state EXECUTE --blast-radius LOW
expect_error "missing agent" "--agent is required" bash "$GUARD" --state EXECUTE
expect_error "missing state source" "Either --contract, --contract-dir, or --state is required" bash "$GUARD" --agent developer
expect_error "conflicting state selectors" "mutually exclusive" bash "$GUARD" --agent developer --state EXECUTE --contract "$D/missing.json"
expect_error "repeated state selector" "mutually exclusive" bash "$GUARD" --agent developer --state EXECUTE --state REVIEW

if bash "$GUARD" --agent developer --state EXECUTE >/dev/null 2>&1; then
  pass=$((pass+1))
else
  fail=$((fail+1)); echo "FAIL valid invocation was rejected"
fi
if bash "$GUARD" --help >/dev/null 2>&1; then
  pass=$((pass+1))
else
  fail=$((fail+1)); echo "FAIL explicit help did not exit successfully"
fi

echo "T22 state guard CLI: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
