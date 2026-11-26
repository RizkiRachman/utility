#!/usr/bin/env bash
# T18-learning-impact.sh — learning reuse is recorded and reported.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$SCRIPT_DIR/../.." && pwd)"
S="$ENGINE/scripts/learning-record.sh"
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
export LEARNING_LOG="$D/records.jsonl" LEARNING_HITS_LOG="$D/hits.jsonl"
printf 'evidence' > "$D/ev.md"
pass=0; fail=0
ok() { [[ "$2" == "$3" ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $1: expected $3, got $2"; }; }

$S write --key k1 --claim "lesson" --evidence "file:$D/ev.md" --verified-by qa --source-task t0 >/dev/null 2>&1
# No hits yet.
$S impact > "$D/i1.json" 2>/dev/null
ok "initial hits" "$(jq -r .total_hits "$D/i1.json")" "0"
ok "initial key hits" "$(jq -r '.keys[0].hits' "$D/i1.json")" "0"

# Reuse across two tasks.
$S hit --key k1 --source-task A >/dev/null 2>&1
$S hit --key k1 --source-task B >/dev/null 2>&1
$S impact > "$D/i2.json" 2>/dev/null
ok "total hits" "$(jq -r .total_hits "$D/i2.json")" "2"
ok "key hits" "$(jq -r '.keys[0].hits' "$D/i2.json")" "2"
ok "reused across tasks" "$(jq -r '.keys[0].reused_across_tasks' "$D/i2.json")" "2"

# Unknown key cannot be recorded as a hit.
$S hit --key missing --source-task A >/dev/null 2>&1; rc=$?
ok "unknown key exit" "$rc" "1"

# Expired records are excluded from impact.
$S write --key old --claim "expired" --evidence "file:$D/ev.md" --verified-by qa --ttl-days -1 >/dev/null 2>&1
$S impact > "$D/i3.json" 2>/dev/null
ok "expired excluded" "$(jq -r '[.keys[].key] | index("old")' "$D/i3.json")" "null"

echo "T18 learning impact: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
