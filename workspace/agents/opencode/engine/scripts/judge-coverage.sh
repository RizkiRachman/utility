#!/usr/bin/env bash
# judge-coverage.sh — report independent-judge coverage from the scores ledger.
# Reads JSONL written by auto-score.sh; tolerates blank/malformed lines.
# Usage: judge-coverage.sh [ledger-path]  (default: session/scores.jsonl)
set -uo pipefail
LEDGER="${1:-session/scores.jsonl}"

if [[ ! -f "$LEDGER" ]]; then
    printf '{"entries":0,"judge_backed":0,"tier1_only":0,"coverage_pct":0,"verdicts":{}}\n'
    exit 0
fi

jq -R -s '
  split("\n")
  | map(select(length > 0))
  | map(fromjson? // empty) as $rows
  | ($rows | length) as $n
  | ($rows | map(select(.tier1_only == false)) | length) as $j
  | {
      entries: $n,
      judge_backed: $j,
      tier1_only: ($n - $j),
      coverage_pct: (if $n == 0 then 0 else (($j * 100 / $n) | floor) end),
      verdicts: ($rows | group_by(.verdict) | map({key: (.[0].verdict // "unknown"), value: length}) | from_entries)
    }
' "$LEDGER"
