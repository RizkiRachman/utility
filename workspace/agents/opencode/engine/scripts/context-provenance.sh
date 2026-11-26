#!/usr/bin/env bash
# context-provenance.sh — provenance for context used in a task.
# Each record ties a retrieved snippet/file to a source path, commit,
# retrieval timestamp, retrieval tool, and evidence status.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="${PROVENANCE_LOG:-session/context-provenance.jsonl}"
OP="${1:-}"; [[ $# -gt 0 ]] && shift
SOURCE=""; COMMIT="HEAD"; TOOL="unknown"; STATUS=""; TASK=""; NOTE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --source) SOURCE="$2"; shift 2 ;; --commit) COMMIT="$2"; shift 2 ;;
    --tool) TOOL="$2"; shift 2 ;; --status) STATUS="$2"; shift 2 ;;
    --task) TASK="$2"; shift 2 ;; --note) NOTE="$2"; shift 2 ;;
    *) echo "context-provenance.sh: unknown arg $1" >&2; exit 2 ;;
  esac
done
valid_status() { [[ "$1" == verified || "$1" == observed-once || "$1" == unverified ]]; }
parse_records() {
  jq -R -s 'split("\n") | map(select(length > 0)) | map(try fromjson catch null) | map(select(type == "object"))' "$LOG" 2>/dev/null || echo "[]"
}
case "$OP" in
  record)
    [[ -n "$SOURCE" ]] || { echo "usage: ... record --source PATH --status verified|observed-once|unverified [--tool NAME --commit SHA]" >&2; exit 2; }
    valid_status "$STATUS" || { echo "context-provenance: invalid status $STATUS" >&2; exit 1; }
    [[ -f "$SOURCE" ]] || { echo "context-provenance: source not found: $SOURCE" >&2; exit 1; }
    resolved=$(git rev-parse --short HEAD 2>/dev/null || true)
    [[ -n "$resolved" ]] && COMMIT="$resolved"
    mkdir -p "$(dirname "$LOG")" || exit 1
    jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg s "$SOURCE" --arg c "$COMMIT" \
      --arg t "$TOOL" --arg st "$STATUS" --arg k "$TASK" --arg n "$NOTE" \
      '{id:($ts + "-" + $s),ts:$ts,source:$s,commit:$c,tool:$t,evidence_status:$st,task_id:$k,note:$n}' >> "$LOG" || exit 1
    echo "recorded: $SOURCE ($STATUS @ $COMMIT)" ;;
  validate)
    [[ -n "$SOURCE" ]] || { echo "usage: ... validate --source PATH" >&2; exit 2; }
    [[ -f "$LOG" ]] || { echo "NO provenance for $SOURCE" >&2; exit 1; }
    found=$(parse_records | jq -r --arg s "$SOURCE" 'map(select(.source == $s and .evidence_status == "verified")) | length')
    [[ "$found" -ge 1 && -f "$SOURCE" ]] || { echo "NO verified provenance for $SOURCE" >&2; exit 1; }
    echo "VERIFIED provenance for $SOURCE" ;;
  report)
    [[ -f "$LOG" ]] || { printf '{"records":0,"verified":0,"by_tool":{},"by_status":{},"stale_sources":[]}\n'; exit 0; }
    stale=$(parse_records | jq -r '.[].source' | while IFS= read -r src; do
      [[ -n "$src" && ! -f "$src" ]] && printf '%s\n' "$src"
    done | jq -R -s 'split("\n") | map(select(length > 0))')
    parse_records | jq --argjson stale "$stale" '
      . as $r
      | ($r | map(select(.evidence_status == "verified")) | length) as $v
      | {
          records: ($r | length),
          verified: $v,
          by_tool: ($r | group_by(.tool) | map({key:(.[0].tool // "unknown"), value:length}) | from_entries),
          by_status: ($r | group_by(.evidence_status) | map({key:(.[0].evidence_status // "unknown"), value:length}) | from_entries),
          stale_sources: $stale
        }
    ' ;;
  *) echo "usage: context-provenance.sh {record|validate|report} [flags]" >&2; exit 2 ;;
esac
