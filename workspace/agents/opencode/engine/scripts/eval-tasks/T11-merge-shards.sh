#!/usr/bin/env bash
# T11-merge-shards.sh — parallel shard merge is conflict-safe and atomic.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$SCRIPT_DIR/../.." && pwd)"
S="$ENGINE/scripts/merge-shards.sh"
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
mkdir -p "$D/a" "$D/b" "$D/target"
printf 'A' > "$D/a/x.md"; printf 'B' > "$D/b/y.md"
printf 'old' > "$D/target/x.md"
pass=0; fail=0
ok() { [[ "$2" == "$3" ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $1: expected $3, got $2"; }; }
manifest() { printf '[{"name":"a","dir":"%s/a","files":["x.md"]},{"name":"b","dir":"%s/b","files":["%s"]}]' "$D" "$D" "$1" > "$D/m.json"; }
field() { jq -r ".$1" "$D/report.json"; }

manifest y.md
bash "$S" --manifest "$D/m.json" --target "$D/target" --report "$D/report.json" >/dev/null 2>&1
ok "apply status" "$(field status)" "applied"
ok "apply count" "$(field applied)" "2"
ok "content a" "$(cat "$D/target/x.md")" "A"
ok "content b" "$(cat "$D/target/y.md")" "B"

manifest x.md
bash "$S" --manifest "$D/m.json" --target "$D/target" --report "$D/report.json" >/dev/null 2>&1; rc=$?
ok "conflict exit" "$rc" "1"
ok "conflict status" "$(field status)" "conflict"
ok "conflict unchanged" "$(cat "$D/target/x.md")" "A"

manifest '../x.md'
bash "$S" --manifest "$D/m.json" --target "$D/target" --report "$D/report.json" >/dev/null 2>&1; rc=$?
ok "unsafe exit" "$rc" "1"
ok "unsafe status" "$(field status)" "invalid"

manifest 'z.md'
bash "$S" --manifest "$D/m.json" --target "$D/target" --report "$D/report.json" >/dev/null 2>&1; rc=$?
ok "missing exit" "$rc" "1"
ok "missing status" "$(field status)" "invalid"

manifest y.md
bash "$S" --manifest "$D/m.json" --target "$D/target" --dry-run --report "$D/report.json" >/dev/null 2>&1
ok "dry status" "$(field status)" "dry_run"
ok "dry applied" "$(field applied)" "0"

printf '[{"name":"a","dir":"%s/nope","files":["x.md"]}]' "$D" > "$D/m.json"
bash "$S" --manifest "$D/m.json" --target "$D/target" --report "$D/report.json" >/dev/null 2>&1; rc=$?
ok "missing shard exit" "$rc" "1"
ok "missing shard status" "$(field status)" "invalid"

echo "T11 merge shards: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
