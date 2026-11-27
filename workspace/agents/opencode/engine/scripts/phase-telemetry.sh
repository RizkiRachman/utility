#!/usr/bin/env bash
# phase-telemetry.sh — per-phase wall-clock and token telemetry.
# start/stop emit paired events keyed by run_id; report aggregates only
# completed runs. Malformed rows and orphaned starts never inflate output.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="${TELEMETRY_LOG:-session/telemetry.jsonl}"
CONTRACT="${CONTRACT_FILE:-session/contract.json}"
OP="${1:-}"; [[ $# -gt 0 ]] && shift
PHASE=""; CLASS=""; TASK=""; RUN=""; TOKIN="0"; TOKOUT="0"; VERDICT=""; PHASES=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase) PHASE="$2"; shift 2 ;; --class) CLASS="$2"; shift 2 ;;
    --task) TASK="$2"; shift 2 ;; --run-id) RUN="$2"; shift 2 ;;
    --tokens-in) TOKIN="$2"; shift 2 ;; --tokens-out) TOKOUT="$2"; shift 2 ;;
    --verdict) VERDICT="$2"; shift 2 ;;
    --phases) PHASES="$2"; shift 2 ;;
    *) echo "phase-telemetry.sh: unknown arg $1" >&2; exit 2 ;;
  esac
done
if [[ -z "$CLASS" && -f "$CONTRACT" ]]; then
  CLASS=$(jq -r '.session.task_class // "unclassified"' "$CONTRACT" 2>/dev/null || echo unclassified)
fi
if [[ -z "$TASK" && -f "$CONTRACT" ]]; then
  TASK=$(jq -r '.session.task_id // "unknown"' "$CONTRACT" 2>/dev/null || echo unknown)
fi
CLASS="${CLASS:-unclassified}"; TASK="${TASK:-unknown}"
now_ms() {
  local ms
  ms=$(date +%s%3N 2>/dev/null || true)
  if [[ "$ms" =~ ^[0-9]+$ ]]; then printf '%s\n' "$ms"; else
    python3 -c 'import time; print(int(time.time()*1000))'
  fi
}
append() { mkdir -p "$(dirname "$LOG")" || return 1; printf '%s\n' "$1" >> "$LOG" || return 1; }

case "$OP" in
  start)
    [[ -n "$PHASE" ]] || { echo "usage: ... start --phase NAME [--class C --task ID]" >&2; exit 2; }
    run="$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM"
    event=$(jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson ms "$(now_ms)" \
      --arg r "$run" --arg p "$PHASE" --arg c "$CLASS" --arg t "$TASK" \
      '{event:"start",run_id:$r,ts:$ts,started_ms:$ms,phase:$p,task_class:$c,task_id:$t}') || exit 1
    append "$event" || exit 1
    echo "$run" ;;
  stop)
    [[ -n "$RUN" ]] || { echo "usage: ... stop --run-id ID [--tokens-in N --tokens-out N --verdict V]" >&2; exit 2; }
    for token_count in "$TOKIN" "$TOKOUT"; do
      [[ "$token_count" =~ ^(0|[1-9][0-9]*)$ ]] || { echo "token counts must be non-negative integers" >&2; exit 2; }
    done
    [[ -f "$LOG" ]] || { echo "unknown run $RUN" >&2; exit 1; }
    meta=$(jq -r --arg r "$RUN" 'select(type=="object" and .event=="start" and .run_id==$r) | [(.started_ms // empty), (.phase // "unknown"), (.task_class // "unclassified")] | @tsv' "$LOG" 2>/dev/null | tail -1)
    [[ -n "$meta" ]] || { echo "unknown run $RUN" >&2; exit 1; }
    started=$(printf '%s' "$meta" | cut -f1)
    phase=$(printf '%s' "$meta" | cut -f2)
    class=$(printf '%s' "$meta" | cut -f3)
    elapsed=$(( $(now_ms) - started ))
    event=$(jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson ms "$(now_ms)" \
      --arg r "$RUN" --argjson e "$elapsed" --argjson ti "${TOKIN:-0}" --argjson to "${TOKOUT:-0}" \
      --arg v "${VERDICT:-unknown}" --arg p "$phase" --arg c "$class" \
      '{event:"stop",run_id:$r,ts:$ts,ended_ms:$ms,elapsed_ms:$e,tokens_in:$ti,tokens_out:$to,verdict:$v,phase:$p,task_class:$c}') || exit 1
    append "$event" || exit 1
    echo "run=$RUN elapsed_ms=$elapsed" ;;
  report)
    [[ -f "$LOG" ]] || { printf '{"runs":0,"total_elapsed_ms":0,"avg_elapsed_ms":0,"tokens_in":0,"tokens_out":0,"by_phase":{},"by_class":{}}\n'; exit 0; }
    jq -R -s '
      split("\n") | map(select(length > 0)) | map(try fromjson catch null)
      | map(select(type == "object")) as $r
      | ($r | map(select(.event=="start" and (.run_id | type=="string" and length>0)) | .run_id) | unique) as $started
      | ($r | map(select(
          .event=="stop"
          and (.run_id | type=="string" and length>0)
          and (.elapsed_ms | type=="number" and . >= 0)
          and ((.tokens_in // 0) | type=="number" and . >= 0)
          and ((.tokens_out // 0) | type=="number" and . >= 0)
          and (.run_id as $id | ($started | index($id)) != null)
        )) | unique_by(.run_id)) as $s
      | ($s | length) as $n
      | ($s | map(.elapsed_ms // 0) | add // 0) as $tot
      | {
          runs: $n,
          total_elapsed_ms: $tot,
          avg_elapsed_ms: (if $n == 0 then 0 else ($tot / $n | floor) end),
          tokens_in: ($s | map(.tokens_in // 0) | add // 0),
          tokens_out: ($s | map(.tokens_out // 0) | add // 0),
          by_phase: ($s | group_by(.phase) | map({key:(.[0].phase // "unknown"), value:length}) | from_entries),
          by_class: ($s | group_by(.task_class) | map({key:(.[0].task_class // "unknown"), value:length}) | from_entries)
        }
    ' "$LOG" ;;
  active)
    [[ -f "$LOG" ]] || { echo "[]"; exit 0; }
    jq -R -s '
      split("\n") | map(select(length > 0)) | map(try fromjson catch null)
      | map(select(type == "object")) as $r
      | ($r | map(select(
          .event=="stop"
          and (.run_id | type == "string" and length > 0)
          and (.elapsed_ms | type == "number" and . >= 0)
          and ((.tokens_in // 0) | type == "number" and . >= 0)
          and ((.tokens_out // 0) | type == "number" and . >= 0)
        ) | .run_id) | unique) as $sp
      | [ $r[]
          | select(.event=="start" and (.run_id | type == "string" and length > 0))
          | .run_id
          | select(. as $x | ($sp | index($x)) == null)
        ] | unique
    ' "$LOG" ;;
  coverage)
    if [[ -f "$LOG" ]]; then
      out=$(jq -R -s --arg cls "$CLASS" --arg task "$TASK" --arg phases "$PHASES" '
        split("\n") | map(select(length > 0)) | map(try fromjson catch null)
        | map(select(type == "object")) as $r
        | ($r | map(select(
            .event=="stop"
            and (.run_id | type == "string" and length > 0)
            and (.elapsed_ms | type == "number" and . >= 0)
            and ((.tokens_in // 0) | type == "number" and . >= 0)
            and ((.tokens_out // 0) | type == "number" and . >= 0)
          ) | .run_id) | unique) as $sp
        | ($r | map(select(.event=="start" and (.run_id as $x | ($sp|index($x)) != null)))) as $done
        | (if $phases != "" then ($phases|split(","))
           elif ($cls=="trivial" or $cls=="prototype") then ["EXECUTE"]
           else ["PLAN","EXECUTE","REVIEW"] end) as $expected
        | ($done | map(select((.task_class//"unclassified")==$cls and (.task_id//"unknown")==$task) | .phase)) as $ph
        | ($expected | map(select(. as $p | ($ph|index($p)) != null))) as $covered
        | ($expected | map(select(. as $p | ($ph|index($p)) == null))) as $missing
        | {class:$cls, task:$task, expected:$expected, covered:$covered, missing:$missing,
           status:(if ($missing|length)==0 then "complete" else "incomplete" end)}
      ' "$LOG") || exit 1
    else
      expected='["PLAN","EXECUTE","REVIEW"]'
      [[ "$CLASS" == "trivial" || "$CLASS" == "prototype" ]] && expected='["EXECUTE"]'
      [[ -n "$PHASES" ]] && expected=$(printf '%s' "$PHASES" | jq -R 'split(",")')
      out=$(jq -cn --arg cls "$CLASS" --arg task "$TASK" --argjson e "$expected" '{class:$cls,task:$task,expected:$e,covered:[],missing:$e,status:"incomplete"}')
    fi
    printf '%s\n' "$out"
    [[ "$(printf '%s' "$out" | jq -r .status)" == "complete" ]] ;;
  *) echo "usage: phase-telemetry.sh {start|stop|report|active|coverage} [flags]" >&2; exit 2 ;;
esac
