#!/usr/bin/env bash
# metrics-aggregator.sh — Cross-session quality metrics aggregation
# Usage: scripts/metrics-aggregator.sh [--mode MODE] [--days N] [--session B] [--json]
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --mode MODE      summary|by-state|timeline|quality|monthly (default: summary)
  --days N         Lookback window (default: 30)
  --session B       Filter to a specific session
  --json           Machine-readable output
  --verbose        Verbose output

Modes:
  summary   Aggregate overview (total iterations, avg score, pass rate)
  by-state  Distribution of state outcomes (COMPLETE/BLOCKED/RETRY)
  timeline  Chronological score sequence by session
  quality   Composite quality score (avg × pass_rate / block_rate)
  monthly   Month-over-month score trend into session/eval-report.md

EOF
    exit 0
}

# mstats MONTH LEDGER - prints count, avg combined, pass count
mstats() {
    local month="$1" ledger="$2"
    jq -r --arg m "$month" 'select(.timestamp[0:7] == $m) | "\(.combined) \(.verdict)"' "$ledger" 2>/dev/null | awk '{n++; s+=$1; if ($2=="PASS") p++} END {if (n==0) print "0 0 0"; else printf "%d %.1f %d\n", n, s/n, p}'
}

# Monthly month-over-month score trend (R2-15): reads the auto-score.sh
# JSONL ledger and writes session/eval-report.md. Gracefully handles an
# absent or empty ledger (fresh clones, first month).
mode_monthly() {
    local ledger="session/scores.jsonl"
    local report="session/eval-report.md"
    local this_month prev_month
    this_month=$(date -u +%Y-%m)
    local py pm
    py="$(date -u +%Y)"
    pm=$((10#$(date -u +%m)))
    if [[ "$pm" -eq 1 ]]; then py=$((py-1)); pm=12; else pm=$((pm-1)); fi
    prev_month="$(printf '%04d-%02d' "$py" "$pm")"

    if [[ ! -f "$ledger" ]]; then
        {
            echo "# Eval Report - ${this_month}"
            echo ""
            echo "No scores ledger at ${ledger}; nothing to aggregate yet."
            echo "Populate it via auto-score.sh (runs after every scoring pass)."
        } > "$report"
        log_info "No scores ledger; wrote empty report to ${report}"
        return 0
    fi
    local cur_n cur_avg cur_pass prev_n prev_avg prev_pass
    read -r cur_n cur_avg cur_pass <<< "$(mstats "$this_month" "$ledger")"
    read -r prev_n prev_avg prev_pass <<< "$(mstats "$prev_month" "$ledger")"
    {
        echo "# Eval Report - ${this_month}"
        echo ""
        echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo ""
        echo "| Month | Runs | Avg combined | PASS |"
        echo "|---|---|---|---|"
        echo "| ${prev_month} | ${prev_n} | ${prev_avg} | ${prev_pass} |"
        echo "| ${this_month} | ${cur_n} | ${cur_avg} | ${cur_pass} |"
        echo ""
        if [[ "${cur_n}" -eq 0 && "${prev_n}" -eq 0 ]]; then
            echo "No scored runs in either month yet."
        elif [[ "${cur_n}" -eq 0 ]]; then
            echo "No runs this month; trend unavailable."
        else
            echo "Avg combined moved from ${prev_avg} to ${cur_avg}."
        fi
    } > "$report"
    log_info "Eval report written to ${report}"
}

MODE="summary"
DAYS=30
SESSION_ID=""
JSON="false"
VERBOSE="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode) MODE="$2"; shift ;;
        --days) DAYS="$2"; shift ;;
        --session) SESSION_ID="$2"; shift ;;
        --json) JSON="true" ;;
        --verbose) VERBOSE="true" ;;
        --help|-h) usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
    shift
done

collect_metrics() {
    local session_filter="$1"
    local now; now=$(date +%s)
    local cutoff=$((now - DAYS * 86400))
    local state_file="session/state.md"

    if [[ -f "$state_file" ]]; then
        # session/state.md rows: | Timestamp | Session | State | Score | Hash | Summary |
        while IFS='|' read -r _ ts sess st sc _hash _rest; do
            ts="$(echo "$ts" | xargs)"; sess="$(echo "$sess" | xargs)"
            st="$(echo "$st" | xargs)"; sc="$(echo "$sc" | xargs)"
            [[ "$ts" == "Timestamp" || -z "$ts" ]] && continue
            [[ -n "$session_filter" && "$session_filter" != "$sess" ]] && continue
            local epoch; epoch=$(date -d "$ts" +%s 2>/dev/null || echo "0")
            [[ "$epoch" -lt "$cutoff" ]] && continue
            echo "$ts|$sess|$st|$sc"
        done < "$state_file" | sort -t'|' -k1
        return
    fi

    # Fallback: live contract only
    if [[ -f session/contract.json ]]; then
        local st sc ts
        st=$(jq -r '.state // "UNKNOWN"' session/contract.json 2>/dev/null)
        sc=$(jq -r '.score.combined // .score // 0' session/contract.json 2>/dev/null)
        ts=$(jq -r '.session.created_at // .timestamp // "unknown"' session/contract.json 2>/dev/null)
        echo "$ts|session|$st|$sc"
    fi
}

mode_summary() {
    local metrics="$1"
    local total=$(echo "$metrics" | wc -l | tr -d ' ')
    local completes=$(echo "$metrics" | grep -c '|COMPLETE|' || echo "0")
    local blocked=$(echo "$metrics" | grep -c '|BLOCKED|' || echo "0")
    local avg_score=$(echo "$metrics" | cut -d'|' -f4 | awk '{sum+=$1; count++} END {printf "%.1f", sum/count}')
    local pass_rate=$((completes * 100 / total))
    local block_rate=$((blocked * 100 / total))
    
    if [[ "$JSON" == "true" ]]; then
        echo "{\"total\":$total,\"avg_score\":$avg_score,\"pass_rate\":$pass_rate,\"block_rate\":$block_rate}"
    else
        log_info "=== Summary Metrics ==="
        printf "  Total sessions:  %d\n" $total
        printf "  Avg score:       %.1f\n" $avg_score
        printf "  Pass rate:       %d%%\n" $pass_rate
        printf "  Block rate:      %d%%\n" $block_rate
    fi
}

mode_by_state() {
    local metrics="$1"
    local total=$(echo "$metrics" | wc -l | tr -d ' ')
    local completes=$(echo "$metrics" | grep -c '|COMPLETE|' || echo "0")
    local blocked=$(echo "$metrics" | grep -c '|BLOCKED|' || echo "0")
    local retry=$(echo "$metrics" | grep -c '|RETRY|' || echo "0")
    local other=$((total - completes - blocked - retry))
    
    if [[ "$JSON" == "true" ]]; then
        echo "{\"COMPLETE\":$completes,\"BLOCKED\":$blocked,\"RETRY\":$retry,\"OTHER\":$other}"
    else
        log_info "=== State Distribution ==="
        printf "  COMPLETE: %d (%.1f%%)\n" $completes $(echo "$completes * 100 / $total" | bc -l)
        printf "  BLOCKED:  %d (%.1f%%)\n" $blocked $(echo "$blocked * 100 / $total" | bc -l)
        printf "  RETRY:    %d (%.1f%%)\n" $retry $(echo "$retry * 100 / $total" | bc -l)
        printf "  OTHER:    %d (%.1f%%)\n" $other $(echo "$other * 100 / $total" | bc -l)
    fi
}

mode_timeline() {
    local metrics="$1"
    if [[ "$JSON" == "true" ]]; then
        echo "$metrics" | while IFS='|' read -r ts br st sc; do
            echo "{\"timestamp\":\"$ts\",\"session\":\"$br\",\"state\":\"$st\",\"score\":$sc}"
        done | jq -s '.'
    else
        log_info "=== Score Timeline ==="
        echo "$metrics" | while IFS='|' read -r ts br st sc; do
            printf "  %-20s | %-30s | %-8s | %3d\n" "$ts" "$br" "$st" "$sc"
        done
    fi
}

mode_quality() {
    local metrics="$1"
    local total=$(echo "$metrics" | wc -l | tr -d ' ')
    local completes=$(echo "$metrics" | grep -c '|COMPLETE|' || echo "0")
    local blocked=$(echo "$metrics" | grep -c '|BLOCKED|' || echo "1")
    local avg_score=$(echo "$metrics" | cut -d'|' -f4 | awk '{sum+=$1; count++} END {printf "%.1f", sum/count}')
    local pass_rate=$((completes * 100 / total))
    local block_rate=$((blocked * 100 / total))
    [[ $block_rate -eq 0 ]] && block_rate=1
    local quality=$(echo "$avg_score * $pass_rate / $block_rate" | bc -l | cut -d'.' -f1)
    
    if [[ "$JSON" == "true" ]]; then
        echo "{\"quality_score\":$quality,\"avg_score\":$avg_score,\"pass_rate\":$pass_rate,\"block_rate\":$block_rate}"
    else
        log_info "=== Composite Quality Score ==="
        printf "  Quality:     %d (avg_score × pass_rate / block_rate)\n" $quality
        printf "  Avg score:   %.1f\n" $avg_score
        printf "  Pass rate:   %d%%\n" $pass_rate
        printf "  Block rate:  %d%%\n" $block_rate
    fi
}

# ── Persist aggregated metrics (rules.json → metrics.cross_session_quality.store_in)
# Destination resolved by the scripts/lib store_in_path() helper: the raw
# store_in value at .metrics.cross_session_quality.store_in (engine-relative),
# with the hardcoded fallback below. Runtime state lives under session/
# (consistent with feedback.post_mortem.store_in → session/post-mortems/);
# the value is session/quality-metrics.json.

persist_metrics() {
    local metrics="$1"
    local out; out="$(store_in_path "metrics.cross_session_quality.store_in" "session/quality-metrics.json")"
    local total completes blocked retried avg_score pass_rate block_rate
    total=$(echo "$metrics" | wc -l | tr -d ' ')
    completes=$(echo "$metrics" | grep -c '|COMPLETE|' || true); completes=${completes:-0}
    blocked=$(echo "$metrics" | grep -c '|BLOCKED|' || true); blocked=${blocked:-0}
    retried=$(echo "$metrics" | grep -c '|RETRY|' || true); retried=${retried:-0}
    avg_score=$(echo "$metrics" | cut -d'|' -f4 | awk '{s+=$1; c++} END {if (c > 0) printf "%.1f", s/c; else print "0"}')
    pass_rate=$((completes * 100 / total))
    block_rate=$((blocked * 100 / total))

    mkdir -p "$(dirname "$out")"
    jq -n \
        --arg generated_at "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
        --arg mode "$MODE" \
        --arg session "${SESSION_ID:-all}" \
        --argjson days "$DAYS" \
        --argjson total "$total" \
        --argjson complete "$completes" \
        --argjson blocked "$blocked" \
        --argjson retry "$retried" \
        --argjson avg_score "$avg_score" \
        --argjson pass_rate "$pass_rate" \
        --argjson block_rate "$block_rate" \
        '{generated_at: $generated_at, mode: $mode, session_filter: $session, window_days: $days, totals: {sessions: $total, complete: $complete, blocked: $blocked, retry: $retry}, summary: {avg_score: $avg_score, pass_rate: $pass_rate, block_rate: $block_rate}}' \
        > "$out"

    if [[ "$JSON" != "true" ]]; then
        log_pass "Metrics persisted to $out (rules.json → .metrics.cross_session_quality.store_in)"
    fi
}

main() {
    local metrics=$(collect_metrics "$SESSION_ID")
    
    if [[ -z "$metrics" ]]; then
        log_info "No metrics found in session/"
        exit 0
    fi
    
    case "$MODE" in
        summary) mode_summary "$metrics" ;;
        by-state) mode_by_state "$metrics" ;;
        timeline) mode_timeline "$metrics" ;;
        quality) mode_quality "$metrics" ;;
        monthly) mode_monthly ;;
        *) echo "Unknown mode: $MODE" >&2; exit 1 ;;
    esac

    persist_metrics "$metrics"
}

main