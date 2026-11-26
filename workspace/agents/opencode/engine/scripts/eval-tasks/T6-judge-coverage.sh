#!/usr/bin/env bash
# T6-judge-coverage.sh — malformed rows must never count as judge evidence.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$SCRIPT_DIR/../judge-coverage.sh"
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
pass=0; fail=0
expect() {
  local label="$1" file="$2" key="$3" want="$4"
  local got; got=$(bash "$S" "$file" 2>/dev/null | jq -r "$key")
  if [[ "$got" == "$want" ]]; then pass=$((pass+1));
  else fail=$((fail+1)); echo "FAIL $label: $key expected $want, got $got"; fi
}
: > "$D/empty.jsonl"
expect "empty ledger" "$D/empty.jsonl" ".coverage_pct" "0"
printf '%s\n' '{"verdict":"RETRY","tier1_only":true}' > "$D/t1.jsonl"
expect "tier1 only" "$D/t1.jsonl" ".coverage_pct" "0"
printf '%s\n' '{"verdict":"PASS","tier1_only":false}' '{"verdict":"RETRY","tier1_only":true}' '{"verdict":"PASS","tier1_only":false}' > "$D/mixed.jsonl"
expect "mixed coverage" "$D/mixed.jsonl" ".coverage_pct" "66"
printf '%s\n' '{"verdict":"PASS","tier1_only":false}' '{bad json' '42' > "$D/bad.jsonl"
expect "malformed counted" "$D/bad.jsonl" ".malformed" "2"
expect "malformed not judge" "$D/bad.jsonl" ".coverage_pct" "33"
expect "malformed separate from tier1" "$D/bad.jsonl" ".tier1_only" "0"
printf '%s\n' '{"verdict":"PASS","tier1_only":false}' '{"verdict":"RETRY","tier1_only":true}' '{bad json' > "$D/bad2.jsonl"
expect "valid tier1 with malformed" "$D/bad2.jsonl" ".tier1_only" "1"
expect "valid tier1 with malformed coverage" "$D/bad2.jsonl" ".coverage_pct" "33"
echo "T6 judge coverage: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
