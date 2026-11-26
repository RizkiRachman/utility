#!/usr/bin/env bash
# judge-coverage.sh — independent-judge coverage from the scores ledger.
# Malformed or non-object rows count as NOT judge-backed; they can never
# inflate coverage. Usage: judge-coverage.sh [ledger-path]
set -uo pipefail
LEDGER="${1:-session/scores.jsonl}"

if [[ ! -f "$LEDGER" ]]; then
    printf '{"entries":0,"judge_backed":0,"tier1_only":0,"malformed":0,"coverage_pct":0,"verdicts":{}}\n'
    exit 0
fi

jq -R -s '
  split("\n") | map(select(length > 0)) as $lines
  | ($lines | map(try fromjson catch null)) as $parsed
  | ($parsed | map(select(type == "object"))) as $rows
  | ($lines | length) as $n
  | (($lines | length) - ($rows | length)) as $bad
  | ($rows | map(select(.tier1_only == false)) | length) as $j
  | {
      entries: $n,
      judge_backed: $j,
      tier1_only: ($n - $j - $bad),
      malformed: $bad,
      coverage_pct: (if $n == 0 then 0 else (($j * 100 / $n) | floor) end),
      verdicts: ($rows | group_by(.verdict) | map({key: (.[0].verdict // "unknown"), value: length}) | from_entries)
    }
' "$LEDGER"
