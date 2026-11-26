#!/usr/bin/env bash
# learning-record.sh — durable learning records with evidence, verification, and decay.
# Records are appended to session/learning-records.jsonl. "active" filters out
# expired and unverified entries so stale lessons never guide a new session.
set -uo pipefail
LOG="${LEARNING_LOG:-session/learning-records.jsonl}"
OP="${1:-}"; [[ $# -gt 0 ]] && shift
KEY=""; CAT=""; CLAIM=""; EVIDENCE=""; VERIFIED_BY=""; TTL="90"; TASK=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --key) KEY="$2"; shift 2 ;; --category) CAT="$2"; shift 2 ;;
    --claim) CLAIM="$2"; shift 2 ;; --evidence) EVIDENCE="$2"; shift 2 ;;
    --verified-by) VERIFIED_BY="$2"; shift 2 ;; --ttl-days) TTL="$2"; shift 2 ;;
    --source-task) TASK="$2"; shift 2 ;;
    *) echo "learning-record.sh: unknown arg $1" >&2; exit 2 ;;
  esac
done

case "$OP" in
  write)
    [[ -n "$KEY" && -n "$CLAIM" ]] || { echo "usage: learning-record.sh write --key K --claim TEXT [--category C --evidence CSV --verified-by NAME --ttl-days N --source-task T]" >&2; exit 2; }
    mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
    exp=
    exp=$(date -u -d "+${TTL:-90} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
    jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg k "$KEY" --arg c "${CAT:-lessons}" \
      --arg cl "$CLAIM" --arg e "$EVIDENCE" --arg v "$VERIFIED_BY" --argjson ttl "${TTL:-90}" \
      --arg t "$TASK" --arg exp "$exp" \
      '{ts:$ts,key:$k,category:$c,claim:$cl,evidence:($e|split(",")|map(select(length>0))),verified_by:$v,source_task:$t,ttl_days:$ttl,expires_at:$exp}' >> "$LOG"
    echo "recorded: $KEY (expires $exp)";;
  active)
    [[ -f "$LOG" ]] || { echo "[]"; exit 0; }
    jq -s --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      'map(select(.expires_at > $now and (.verified_by // "") != ""))' "$LOG";;
  audit)
    [[ -f "$LOG" ]] || { echo '{"total":0,"verified":0,"expired":0,"unverified":0}'; exit 0; }
    jq -s --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{total:length, verified:(map(select((.verified_by//"")!=""))|length), expired:(map(select(.expires_at <= $now))|length), unverified:(map(select((.verified_by//"")==""))|length)}' "$LOG";;
  *) echo "usage: learning-record.sh {write|active|audit} [flags]" >&2; exit 2 ;;
esac
