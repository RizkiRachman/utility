#!/usr/bin/env bash
# T25-auto-persist-cli.sh — auto-persist rejects malformed arguments consistently.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$SCRIPT_DIR/../.." && pwd)"
PERSIST="$ENGINE/scripts/auto-persist.sh"
pass=0
fail=0

expect_error() {
  local label="$1" expected="$2" output rc
  shift 2
  if output=$(bash "$PERSIST" "$@" 2>&1); then
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

for option in --file --session --triggered-by; do
  expect_error "$option missing value" "$option requires a value" "$option"
done
expect_error "empty value" "--file requires a value" --file ""
expect_error "option-shaped value" "--session requires a value" --session --no-file
expect_error "unknown option" "Unknown option: --unknown" --unknown

if bash "$PERSIST" --help >/dev/null 2>&1 && bash "$PERSIST" -h >/dev/null 2>&1; then
  pass=$((pass+1))
else
  fail=$((fail+1)); echo "FAIL explicit help did not exit successfully"
fi

echo "T25 auto-persist CLI: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
