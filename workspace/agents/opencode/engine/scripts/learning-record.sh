#!/usr/bin/env bash
# learning-record.sh — durable learning records with evidence, verification, and decay.
# A record is appended only after its evidence references are checked; stable
# keys are updated in place. Write failures are surfaced as a nonzero exit.
set -uo pipefail
LOG="${LEARNING_LOG:-session/learning-records.jsonl}"
HITS="${LEARNING_HITS_LOG:-session/learning-hits.jsonl}"
OP="${1:-}"; [[ $# -gt 0 ]] && shift
KEY=""; CAT=""; CLAIM=""; EVIDENCE=""; VERIFIED_BY=""; TTL="90"; TASK=""; UNVERIFIED=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --key) KEY="$2"; shift 2 ;; --category) CAT="$2"; shift 2 ;;
    --claim) CLAIM="$2"; shift 2 ;; --evidence) EVIDENCE="$2"; shift 2 ;;
    --verified-by) VERIFIED_BY="$2"; shift 2 ;; --ttl-days) TTL="$2"; shift 2 ;;
    --source-task) TASK="$2"; shift 2 ;; --unverified) UNVERIFIED=true; shift ;;
    --hits-file) HITS="$2"; shift 2 ;;
    *) echo "learning-record.sh: unknown arg $1" >&2; exit 2 ;;
  esac
done

validate_evidence() {
  local ev="$1" item kind val
  [[ -n "$ev" ]] || { echo "learning-record: evidence required" >&2; return 1; }
  IFS=',' read -ra items <<< "$ev"
  for item in "${items[@]}"; do
    [[ -n "$item" ]] || continue
    kind="${item%%:*}"; val="${item#*:}"
    case "$kind" in
      file)   [[ -f "$val" ]] || { echo "learning-record: evidence file missing: $val" >&2; return 1; } ;;
      test)   [[ -f "$val" || -f "$val.sh" || -f "scripts/eval-tasks/$val.sh" ]] || { echo "learning-record: evidence test missing: $val" >&2; return 1; } ;;
      pr|commit|review) [[ -n "$val" ]] || return 1 ;;
      *) echo "learning-record: unknown evidence kind: $kind" >&2; return 1 ;;
    esac
  done
}

case "$OP" in
  write)
    [[ -n "$KEY" && -n "$CLAIM" ]] || { echo "usage: learning-record.sh write --key K --claim TEXT --evidence CSV --verified-by NAME [--category C --ttl-days N --source-task T]" >&2; exit 2; }
    [[ "$UNVERIFIED" == true || -n "$VERIFIED_BY" ]] || { echo "learning-record: --verified-by required (or --unverified)" >&2; exit 2; }
    validate_evidence "$EVIDENCE" || exit 1
    mkdir -p "$(dirname "$LOG")" || exit 1
    exp=$(date -u -d "+${TTL:-90} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
    rec=$(jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg k "$KEY" --arg c "${CAT:-lessons}" \
      --arg cl "$CLAIM" --arg e "$EVIDENCE" --arg v "$VERIFIED_BY" --argjson ttl "${TTL:-90}" \
      --arg t "$TASK" --arg exp "$exp" \
      '{id:$k,key:$k,category:$c,claim:$cl,evidence:($e|split(",")|map(select(length>0))),verified_by:$v,source_task:$t,ttl_days:$ttl,created_at:$ts,expires_at:$exp}') || exit 1
    if [[ -f "$LOG" ]]; then
      jq -s -c --arg k "$KEY" --argjson r "$rec" 'map(select(.key != $k)) + [$r] | .[]' "$LOG" > "${LOG}.tmp" || exit 1
    else
      printf '%s\n' "$rec" > "${LOG}.tmp" || exit 1
    fi
    mv "${LOG}.tmp" "$LOG" || exit 1
    echo "recorded: $KEY (expires $exp)";;
  active)
    [[ -f "$LOG" ]] || { echo "[]"; exit 0; }
    jq -s --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      'map(select(.expires_at > $now and (.verified_by // "") != ""))' "$LOG";;
  audit)
    [[ -f "$LOG" ]] || { echo '{"total":0,"verified":0,"expired":0,"unverified":0}'; exit 0; }
    jq -s --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{total:length, verified:(map(select((.verified_by//"")!=""))|length), expired:(map(select(.expires_at <= $now))|length), unverified:(map(select((.verified_by//"")==""))|length)}' "$LOG";;
  hit)
    [[ -n "$KEY" ]] || { echo "usage: learning-record.sh hit --key K [--source-task T]" >&2; exit 2; }
    [[ -f "$LOG" ]] || { echo "learning-record: no active record for $KEY" >&2; exit 1; }
    jq -s -e --arg k "$KEY" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" 'any(.[]; .key==$k and .expires_at > $now)' "$LOG" >/dev/null 2>&1 || { echo "learning-record: no active record for $KEY" >&2; exit 1; }
    mkdir -p "$(dirname "$HITS")" || exit 1
    printf '%s\n' "$(jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg k "$KEY" --arg t "${TASK:-unknown}" '{event:"hit",key:$k,task:$t,ts:$ts}')" >> "$HITS" || exit 1
    echo "hit: $KEY";;
  impact)
    recs='[]'; [[ -f "$LOG" ]] && recs=$(jq -s '.' "$LOG" 2>/dev/null || echo '[]')
    hits='[]'; [[ -f "$HITS" ]] && hits=$(jq -s '.' "$HITS" 2>/dev/null || echo '[]')
    jq -cn --argjson recs "$recs" --argjson hits "$hits" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
      ($recs | map(select(.expires_at > $now and (.verified_by//"") != ""))) as $active
      | ($hits | group_by(.key) | map({key:.[0].key, hits:length, tasks:(map(.task)|unique)})) as $h
      | {total_hits:($hits|length), active_records:($active|length),
         keys:($active | map(. as $r | ($h | map(select(.key==$r.key)) | .[0]) as $m
              | {key:$r.key, claim:$r.claim, hits:(if $m then $m.hits else 0 end),
                 tasks:(if $m then $m.tasks else [] end),
                 reused_across_tasks:(if $m then ($m.tasks|length) else 0 end)}))}
    ';;
  *) echo "usage: learning-record.sh {write|active|audit|hit|impact} [flags]" >&2; exit 2 ;;
esac
