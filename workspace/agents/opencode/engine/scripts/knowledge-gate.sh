#!/usr/bin/env bash
# scripts/knowledge-gate.sh - C5: memory governance gate for ctx_knowledge writes.
# Quality over scale: category, source task, validation tag, rationale required;
# recall-before-write dedup; per-category compaction cap; contamination tagging.
# Exit codes: 0 allow | 2 update-instead-of-insert | 3 compact-oldest-first | 64 usage
# The gate validates and records the LEDGER; the caller runs the actual
# ctx_knowledge remember only on exit 0 (agent.md memory policy).
set -euo pipefail
LEDGER="session/knowledge-ledger.jsonl"
MAXCAT=50
ACTION=""; CATEGORY=""; KEY=""; SRC=""; TAG=""; RATIONALE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    write) ACTION=write; shift ;;
    --category) CATEGORY="$2"; shift 2 ;;
    --key) KEY="$2"; shift 2 ;;
    --source-task) SRC="$2"; shift 2 ;;
    --tag) TAG="$2"; shift 2 ;;
    --rationale) RATIONALE="$2"; shift 2 ;;
    --ledger) LEDGER="$2"; shift 2 ;;
    --max-per-category) MAXCAT="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done
[[ "$ACTION" == "write" ]] || { echo "usage: knowledge-gate.sh write --category C --key K --source-task T --tag verified|observed-once|dead_end --rationale R [--ledger P] [--max-per-category N]" >&2; exit 64; }
fail() { echo "{\"action\":\"reject\",\"reason\":\"$1\"}"; exit 64; }
[[ -n "$CATEGORY" && -n "$KEY" && -n "$SRC" ]] || fail "category, key and source-task are required"
case "$TAG" in verified|observed-once|dead_end) ;; *) fail "tag must be one of: verified | observed-once | dead_end" ;; esac
[[ ${#RATIONALE} -ge 8 ]] || fail "rationale required (>=8 chars): why is this worth storing"
if [[ -f "$LEDGER" ]] && grep -qF "\"category\":\"$CATEGORY\",\"key\":\"$KEY\"" "$LEDGER" 2>/dev/null; then
  echo "{\"action\":\"update-instead-of-insert\",\"reason\":\"duplicate category+key already in ledger\",\"category\":\"$CATEGORY\",\"key\":\"$KEY\"}"
  exit 2
fi
count=0
[[ -f "$LEDGER" ]] && count=$(grep -cF "\"category\":\"$CATEGORY\"" "$LEDGER" 2>/dev/null || true)
if [[ "$count" -ge "$MAXCAT" ]]; then
  echo "{\"action\":\"compact-oldest-first\",\"reason\":\"category at cap\",\"category\":\"$CATEGORY\",\"count\":$count,\"max\":$MAXCAT,\"directive\":\"archive the oldest entries for this category into session/archive/ as compact summaries before writing\"}"
  exit 3
fi
mkdir -p "$(dirname "$LEDGER")"
printf '%s\n' "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"category\":\"$CATEGORY\",\"key\":\"$KEY\",\"source_task\":\"$SRC\",\"tag\":\"$TAG\",\"rationale\":$(printf '%s' "$RATIONALE" | jq -R .)}" >> "$LEDGER"
echo "{\"action\":\"allow\",\"category\":\"$CATEGORY\",\"key\":\"$KEY\",\"tag\":\"$TAG\",\"note\":\"proceed with ctx_knowledge remember; contamination rule: tag=dead_end entries are excluded from governance.current_guidance assembly\"}"
exit 0
