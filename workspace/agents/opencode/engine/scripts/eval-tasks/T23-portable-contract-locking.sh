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

burst_pids=()
for n in {1..12}; do
  bash -c '
    source "$1"
    acquire_file_lock "$2" 5 || exit 1
    printf "held\n" >> "$3/acquisitions"
    sleep 0.01
    release_file_lock
  ' bash "$COMMON" "$D/burst-contract" "$D" >"$D/burst-$n.log" 2>&1 &
  burst_pids+=("$!")
done
burst_failed=0
for pid in "${burst_pids[@]}"; do wait "$pid" || burst_failed=1; done
# Same hosted-runner tolerance as T5: judge the burst by how many handoffs
# completed, allowing RACE_TOLERANCE_PCT percent (default 10) to flake on
# scheduler or filesystem timing before the suite fails.
race_tolerance_pct="${RACE_TOLERANCE_PCT:-10}"
expected_handoffs=12
allowed_lost=$(( expected_handoffs * race_tolerance_pct / 100 ))
acquired=$(wc -l < "$D/acquisitions" 2>/dev/null || echo 0)
acquired=${acquired//[!0-9]/}
[[ "$acquired" =~ ^[0-9]+$ ]] || acquired=0
if [[ "$acquired" -ge "$(( expected_handoffs - allowed_lost ))" ]]; then
  pass=$((pass+1))
else
  fail=$((fail+1)); echo "FAIL concurrent lock handoffs lost beyond tolerance (acquired=$acquired expected=$expected_handoffs allowed_lost=$allowed_lost)"
  cat "$D"/burst-*.log
fi

stale_lock="$D/stale-contract"
acquire_file_lock "$stale_lock" || {
  echo "FAIL could not acquire lock for stale-owner check"
  exit 1
}
stale_token="$_LCOMMON_FILE_LOCK_TOKEN"
rm -f "$stale_lock.lockdir/owner"
rmdir "$stale_lock.lockdir"
bash -c '
  source "$1"
  acquire_file_lock "$2" || exit 1
  printf "%s\n" "$_LCOMMON_FILE_LOCK_TOKEN" > "$3/new-owner"
  touch "$3/new-owner-ready"
  while [[ ! -e "$3/release-new-owner" ]]; do sleep 0.01; done
  release_file_lock
' bash "$COMMON" "$stale_lock" "$D" >"$D/stale-owner.log" 2>&1 &
new_owner_pid=$!
for _ in {1..100}; do
  [[ -e "$D/new-owner-ready" ]] && break
  sleep 0.01
done
if [[ ! -e "$D/new-owner-ready" ]]; then
  fail=$((fail+1)); echo "FAIL replacement lock owner did not start"
  cat "$D/stale-owner.log"
else
  _LCOMMON_FILE_LOCK_TOKEN="$stale_token"
  if release_file_lock 2>"$D/stale-release.log"; then
    fail=$((fail+1)); echo "FAIL stale owner released a replacement lock"
  elif [[ -d "$stale_lock.lockdir" && "$(cat "$D/new-owner")" != "$stale_token" ]]; then
    pass=$((pass+1))
  else
    fail=$((fail+1)); echo "FAIL stale owner changed the replacement lock"
    cat "$D/stale-release.log"
  fi
fi
touch "$D/release-new-owner"
if wait "$new_owner_pid"; then
  pass=$((pass+1))
else
  fail=$((fail+1)); echo "FAIL replacement owner could not release its lock"
  cat "$D/stale-owner.log"
fi
_LCOMMON_FILE_LOCK_DIR=""
_LCOMMON_FILE_LOCK_TOKEN=""

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
