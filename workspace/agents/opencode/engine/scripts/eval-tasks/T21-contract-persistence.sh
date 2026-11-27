#!/usr/bin/env bash
# T21-contract-persistence.sh — persistence locks follow the selected contract.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$SCRIPT_DIR/../.." && pwd)"
PERSIST="$ENGINE/scripts/persist-contract.sh"
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
mkdir -p "$D/session" "$D/custom"
printf '{"session":{"task_id":"lock-test"},"state":"INIT"}\n' > "$D/source.json"
export OPENCODE_PROJECT_ROOT="$D"
pass=0
fail=0

if bash "$PERSIST" --file "$D/custom/contract.json" --from-file "$D/source.json" >/dev/null 2>&1; then
  [[ -f "$D/custom/contract.json.lock" && ! -e "$D/session/contract.json.lock" ]] \
    && pass=$((pass+1)) \
    || { fail=$((fail+1)); echo "FAIL custom contract did not use its own lock path"; }
else
  fail=$((fail+1)); echo "FAIL custom contract persistence failed"
fi

if bash "$PERSIST" --from-file "$D/source.json" >/dev/null 2>&1; then
  [[ -f "$D/session/contract.json.lock" ]] \
    && pass=$((pass+1)) \
    || { fail=$((fail+1)); echo "FAIL default contract lock was not created"; }
else
  fail=$((fail+1)); echo "FAIL default contract persistence failed"
fi

echo "T21 contract persistence: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
