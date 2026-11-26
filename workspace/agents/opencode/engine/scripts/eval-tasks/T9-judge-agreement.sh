#!/usr/bin/env bash
# T9-judge-agreement.sh — labeled verdict corpus with jitter stability check.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX="$SCRIPT_DIR/fixtures/judge-labels.jsonl"
[[ -f "$FIX" ]] || { echo "T9: fixtures missing: $FIX"; exit 1; }

verdict_of() {
  local t1="$1" judge="$2" avail="$3" combined v
  if [[ "$t1" -lt 70 ]]; then combined="$t1"
  else combined=$(( (t1 + judge + 1) / 2 )); fi
  if   [[ "$combined" -ge 70 ]]; then v="PASS"
  elif [[ "$combined" -ge 50 ]]; then v="RETRY"
  else v="BLOCKED"; fi
  [[ "$avail" == false && "$v" == PASS ]] && v="RETRY"
  echo "$v"
}

cases=0; agree=0; false_pass=0; false_block=0; flipped=0
while IFS=$'\t' read -r id t1 judge avail expected; do
  [[ -n "$id" ]] || continue
  cases=$((cases+1))
  if [[ "$judge" == "null" || -z "$judge" ]]; then jv="$t1"; else jv="$judge"; fi
  got=$(verdict_of "$t1" "$jv" "$avail")
  if [[ "$got" == "$expected" ]]; then agree=$((agree+1));
  else
    [[ "$got" == PASS ]] && false_pass=$((false_pass+1))
    [[ "$got" == BLOCKED ]] && false_block=$((false_block+1))
    echo "FAIL $id: expected $expected, got $got"
  fi
  if [[ "$avail" == true ]]; then
    up=$(verdict_of "$t1" "$((jv+5))" "$avail")
    down=$(verdict_of "$t1" "$((jv-5))" "$avail")
    [[ "$up" != "$got" || "$down" != "$got" ]] && flipped=$((flipped+1))
  fi
done < <(jq -r '[.id, .tier1, (.judge // "null"), (.judge_available|tostring), .expected] | @tsv' "$FIX")

cat <<EOF
T9 judge agreement: cases=$cases agreement=$agree false_pass=$false_pass false_block=$false_block flipped_under_jitter=$flipped
EOF
[[ "$false_pass" -eq 0 && "$false_block" -eq 0 && "$agree" -eq "$cases" ]]
