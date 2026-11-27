#!/usr/bin/env bash
# T23-portable-contract-locking.sh — contract writers wait for the shared lock.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMMON="$ENGINE/scripts/lib/common.sh"
PERSIST="$ENGINE/scripts/persist-contract.sh"
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
mkdir -p "$D/session" "$D/custom"
cp "$ENGINE/contract/contract.template.json" "$D/custom/contract.json"
cp "$D/custom/contract.json" "$D/original.json"
printf '{"lock_test":"new"}\n' > "$D/source.json"
LOCK_DIR="$D/custom/contract.json.lockdir"
mkdir "$LOCK_DIR"
pass=0
fail=0

source "$COMMON"
acquire_file_lock "$D/serialized-contract" || {
  echo "FAIL could not acquire initial directory lock"
  exit 1
}
bash -c '
  source "$1"
  touch "$3/waiting"
  acquire_file_lock "$2" || exit 1
  touch "$3/acquired"
  release_file_lock
' bash "$COMMON" "$D/serialized-contract" "$D" &
waiter_pid=$!
for _ in {1..100}; do
  [[ -e "$D/waiting" ]] && break
  sleep 0.01
done
sleep 0.1
if [[ ! -e "$D/acquired" ]]; then
  pass=$((pass+1))
else
  fail=$((fail+1)); echo "FAIL concurrent process entered while the lock was held"
fi
if output=$(bash -c '
  source "$1"
  acquire_file_lock "$2" 0
' bash "$COMMON" "$D/serialized-contract" 2>&1); then
  fail=$((fail+1)); echo "FAIL lock timeout was accepted"
elif [[ "$output" == *"Timed out acquiring lock"* ]]; then
  pass=$((pass+1))
else
  fail=$((fail+1)); echo "FAIL lock timeout did not return a clear error: $output"
fi
release_file_lock
if wait "$waiter_pid" && [[ -e "$D/acquired" && ! -e "$D/serialized-contract.lockdir" ]]; then
  pass=$((pass+1))
else
  fail=$((fail+1)); echo "FAIL waiting process did not acquire and release the lock"
fi

bash "$PERSIST" --file "$D/custom/contract.json" --from-file "$D/source.json" \
  >"$D/writer.log" 2>&1 &
writer_pid=$!
sleep 0.1
if cmp -s "$D/custom/contract.json" "$D/original.json"; then
  pass=$((pass+1))
else
  fail=$((fail+1)); echo "FAIL persistence wrote while the contract lock was held"
fi

rmdir "$LOCK_DIR"
if wait "$writer_pid"; then
  if cmp -s "$D/custom/contract.json" "$D/source.json" && [[ ! -e "$LOCK_DIR" ]]; then
    pass=$((pass+1))
  else
    fail=$((fail+1)); echo "FAIL persistence did not write and release its selected contract lock"
  fi
else
  fail=$((fail+1)); echo "FAIL persistence did not resume after the lock was released"
  cat "$D/writer.log"
fi

echo "T23 portable contract locking: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
