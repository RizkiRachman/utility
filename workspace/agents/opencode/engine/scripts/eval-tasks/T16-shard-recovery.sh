#!/usr/bin/env bash
# T16-shard-recovery.sh — shard merge rolls back on interruption and recovers
# from a persistent journal after abrupt termination.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$SCRIPT_DIR/../.." && pwd)"
S="$ENGINE/scripts/merge-shards.sh"
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
pass=0; fail=0
ok() { [[ "$2" == "$3" ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $1: expected $3, got $2"; }; }

# Setup: two shards, a target with one pre-existing file.
mkdir -p "$D/a" "$D/b" "$D/target"
printf 'NEW-A' > "$D/a/ok.md"; mkdir -p "$D/b/sub"; printf 'NEW-B' > "$D/b/sub/x.md"
printf 'ORIGINAL' > "$D/target/ok.md"
printf '[{"name":"a","dir":"%s/a","files":["ok.md"]},{"name":"b","dir":"%s/b","files":["sub/x.md"]}]' "$D" "$D" > "$D/m.json"

# 1. Clean success applies both and leaves no state dir.
bash "$S" --manifest "$D/m.json" --target "$D/target" --report "$D/r.json" >/dev/null 2>&1
ok "clean apply" "$(cat "$D/target/ok.md")" "NEW-A"
ok "clean state cleaned" "$([[ -d "$D/target/.merge-state" ]] && echo present || echo absent)" "absent"

# 2. Interruption: a regular file blocks a later mkdir; trap rolls back the
#    already-applied file to its original content.
printf 'ORIGINAL2' > "$D/target/ok.md"
rm -rf "$D/target/sub"; printf 'block' > "$D/target/sub"   # 'sub' is a file, so mkdir -p target/sub fails
bash "$S" --manifest "$D/m.json" --target "$D/target" --report "$D/r.json" >/dev/null 2>&1; rc=$?
ok "interrupted exit" "$rc" "1"
ok "interrupted rollback" "$(cat "$D/target/ok.md")" "ORIGINAL2"
ok "interrupted state cleaned" "$([[ -d "$D/target/.merge-state" ]] && echo present || echo absent)" "absent"

# 3. Leftover journal after SIGKILL: --recover restores from the backup.
rm -rf "$D/target/sub"
printf 'ORIGINAL3' > "$D/target/ok.md"
sd="$D/target/.merge-state/killed"
mkdir -p "$sd/backup"
printf 'FROM-BACKUP' > "$sd/backup/ok.md"
printf '%s\n' \
  '{"event":"plan","file":"ok.md","backup":"backup/ok.md"}' \
  '{"event":"plan","file":"gone.md","backup":null}' \
  '{"event":"applied","file":"ok.md"}' \
  '{"event":"applied","file":"gone.md"}' > "$sd/journal.jsonl"
printf 'SHOULD-BE-REMOVED' > "$D/target/gone.md"
bash "$S" --target "$D/target" --recover --report "$D/r2.json" >/dev/null 2>&1
ok "recover status" "$(jq -r .status "$D/r2.json")" "recovered"
ok "recover restored backup" "$(cat "$D/target/ok.md")" "FROM-BACKUP"
ok "recover removed absent file" "$([[ -f "$D/target/gone.md" ]] && echo present || echo absent)" "absent"
ok "recover state cleaned" "$([[ -d "$D/target/.merge-state" ]] && echo present || echo absent)" "absent"

# 4. Recover with no state dir is a no-op.
bash "$S" --target "$D/target" --recover --report "$D/r3.json" >/dev/null 2>&1
ok "no-state status" "$(jq -r .status "$D/r3.json")" "no_state"

echo "T16 shard recovery: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
