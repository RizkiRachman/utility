#!/usr/bin/env bash
# trend-analyzer.sh — Score trend analysis and regression detection
# Usage: scripts/trend-analyzer.sh [--mode MODE] [--phase P] [--days N] [--threshold P] [--json] [--view]
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
  --mode MODE       trend|regression|report (default: trend)
  --phase PHASE     PLAN|EXECUTE|REVIEW|ALL (default: ALL)
  --days N          Lookback window (default: 30)
  --threshold P     Regression alert threshold % (default: 15)
  --json            Machine-readable output
  --view            ASCII sparkline for last 10 scores
  --verbose         Verbose output

Modes:
  trend      Analyze score trend direction (improving/declining/stable)
  regression Detect performance regressions (> threshold % drop)
  report     Full trend report with sparkline

EOF
    exit 0
}

get_timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
get_epoch_ms() { date +%s%3N; }

MODE="trend"
PHASE="ALL"
DAYS=30
THRESHOLD=15
JSON="false"
VIEW="false"
VERBOSE="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode) MODE="$2"; shift ;;
        --phase) PHASE="$2"; shift ;;
        --days) DAYS="$2"; shift ;;
        --threshold) THRESHOLD="$2"; shift ;;
        --json) JSON="true" ;;
        --view) VIEW="true" ;;
        --verbose) VERBOSE="true" ;;
        --help|-h) usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
    shift
done

collect_scores() {
    local phase_filter="$1"
    local scores=""
    local session_dir="session"
    
    # Collect scores from session/*/contract.json
    for snap_dir in "$session_dir"/*/; do
        [[ -d "$snap_dir" ]] || continue
        local contract="$snap_dir/contract.json"
        [[ -f "$contract" ]] || continue
        
        local session=$(basename "$snap_dir")
        local timestamp=$(jq -r '.timestamp // .created_at // empty' "$contract" 2>/dev/null || echo "")
        
        # Collect phase scores
        for phase in PLAN EXECUTE REVIEW; do
            [[ "$phase_filter" != "ALL" && "$phase_filter" != "$phase" ]] && continue
            local scored_state="${phase}_SCORED"
            # N6: real paths - audit_log scored transitions, fallback phases_completed
            local score=$(jq -r --arg ss "$scored_state" '.audit_log[]? | select(.new_state == $ss) | (.score // .score_combined // .combined // empty)' "$contract" 2>/dev/null | tail -1)
            if [[ -z "$score" || "$score" == "null" ]]; then
                local inph=$(jq -r --arg ph "$phase" '.metrics.phases_completed // [] | index($ph) != null | tostring' "$contract" 2>/dev/null)
                if [[ "$inph" == "true" ]]; then score=$(jq -r ".score.combined // empty" "$contract" 2>/dev/null); fi
            fi
            [[ -z "$score" || "$score" == "null" ]] && continue
            echo "$timestamp|$session|$phase|$score"
        done
    done | sort -t'|' -k1
}

analyze_trend() {
    local scores="$1"
    local last_scores=$(echo "$scores" | tail -10 | cut -d'|' -f4)
    local first=$(echo "$last_scores" | head -1)
    local last=$(echo "$last_scores" | tail -1)
    
    if [[ -z "$first" || -z "$last" ]]; then
        echo "insufficient_data"
        return
    fi
    
    local delta=$((last - first))
    if [[ $delta -gt 5 ]]; then echo "improving"
    elif [[ $delta -lt -5 ]]; then echo "declining"
    else echo "stable"
    fi
}

detect_regression() {
    local scores="$1"
    local threshold="$2"
    local prev=""
    local regressions=0
    
    while IFS='|' read -r ts br ph score; do
        [[ -z "$score" ]] && continue
        if [[ -n "$prev" ]]; then
            local drop=$((prev - score))
            local pct=$((drop * 100 / prev))
            if [[ $pct -ge $threshold ]]; then
                log_fail "Regression: $pct% drop at $ts ($br/$ph)"
                regressions=$((regressions + 1))
            fi
        fi
        prev="$score"
    done <<< "$scores"
    
    echo "$regressions"
}

sparkline() {
    local scores="$1"
    local bars="▁▂▃▄▅▆▇█"
    local normalized=""
    
    local scores_only=$(echo "$scores" | cut -d'|' -f4)
    local min=$(echo "$scores_only" | sort -n | head -1)
    local max=$(echo "$scores_only" | sort -n | tail -1)
    local range=$((max - min))
    [[ $range -eq 0 ]] && range=1
    
    while read -r score; do
        [[ -z "$score" ]] && continue
        local idx=$(( (score - min) * 8 / range ))
        [[ $idx -gt 7 ]] && idx=7
        [[ $idx -lt 0 ]] && idx=0
        normalized+="${bars:$idx:1}"
    done <<< "$scores_only"
    
    echo "$normalized"
}

main() {
    local scores=$(collect_scores "$PHASE")
    
    if [[ -z "$scores" ]]; then
        log_info "No score data found in session/*/"
        exit 0
    fi
    
    case "$MODE" in
        trend)
            local trend=$(analyze_trend "$scores")
            if [[ "$JSON" == "true" ]]; then
                echo "{\"trend\":\"$trend\",\"samples\":$(echo "$scores" | wc -l | tr -d ' ')}"
            else
                log_info "Score trend: $trend ($(echo "$scores" | wc -l | tr -d ' ') samples over $DAYS days)"
            fi
            ;;
        regression)
            local regressions=$(detect_regression "$scores" "$THRESHOLD")
            if [[ "$JSON" == "true" ]]; then
                echo "{\"regressions\":$regressions,\"threshold\":$THRESHOLD}"
            else
                [[ $regressions -eq 0 ]] && log_pass "No regressions detected (> $THRESHOLD%)"
                log_fail "$regressions regression(s) detected (> $THRESHOLD%)"
            fi
            ;;
        report)
            log_info "=== Score Trend Report ==="
            log_info "Phase: $PHASE | Lookback: $DAYS days | Threshold: $THRESHOLD%"
            echo "$scores" | while IFS='|' read -r ts br ph score; do
                printf "  %s | %-25s | %-8s | %3d\n" "$ts" "$br" "$ph" "$score"
            done
            local trend=$(analyze_trend "$scores")
            log_info "Trend direction: $trend"
            if [[ "$VIEW" == "true" ]]; then
                log_info "Sparkline: $(sparkline "$scores")"
            fi
            ;;
        *)
            echo "Unknown mode: $MODE" >&2
            exit 1
            ;;
    esac
}

main