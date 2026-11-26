#!/usr/bin/env bash
# prompt-budget.sh — measure and gate duplicated instruction text across agents.
# The gate uses character duplication (a token proxy); structural headings that
# legitimately repeat are excluded by the 20-character minimum.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$SCRIPT_DIR/.." && pwd)"
DIR="${1:-$ENGINE/agents}"
MAX="${PROMPT_DUP_MAX:-20}"
[[ -d "$DIR" ]] || { echo "prompt-budget: not a directory: $DIR" >&2; exit 2; }
read -r total_chars dup_chars <<< "$(awk '
  { s=$0; gsub(/^[ \t]+|[ \t]+$/, "", s);
    if (length(s) >= 20) { total += length(s); count[s]++ } }
  END { for (k in count) if (count[k] > 1) dup += length(k) * (count[k] - 1);
        printf "%d %d", total, dup }
' "$DIR"/*.md 2>/dev/null)"
total_chars=${total_chars:-0}; dup_chars=${dup_chars:-0}
content=$(cat "$DIR"/*.md 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | wc -l | tr -d ' ')
unique=$(cat "$DIR"/*.md 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | sort -u | wc -l | tr -d ' ')
if [[ "$total_chars" -eq 0 ]]; then pct=0; else pct=$(( dup_chars * 100 / total_chars )); fi
missing=0
for f in "$DIR"/*.md; do
  grep -q 'engine/shared/protocol.md' "$f" || missing=$((missing+1))
done
status="within_budget"; [[ "$pct" -gt "$MAX" ]] && status="over_budget"
[[ "$missing" -gt 0 ]] && status="missing_shared_protocol"
printf '{"content_lines":%s,"unique_lines":%s,"total_chars":%s,"duplicate_chars":%s,"duplication_pct":%s,"budget_pct":%s,"agents_without_pointer":%s,"status":"%s"}\n' \
  "$content" "$unique" "$total_chars" "$dup_chars" "$pct" "$MAX" "$missing" "$status"
[[ "$status" == "within_budget" ]]
