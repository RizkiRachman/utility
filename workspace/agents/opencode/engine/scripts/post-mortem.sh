#!/usr/bin/env bash
# post-mortem.sh — BLOCKED state post-mortem analysis
# Usage: scripts/post-mortem.sh [--session B] [--mode MODE] [--json]
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
  --session B        Session to analyze (auto-detect)
  --mode MODE       quick|deep|report (default: quick)
  --json            Machine-readable output
  --verbose         Verbose output

Modes:
  quick   Single-session analysis
  deep    Cross-reference similar BLOCKED patterns across sessions
  report  Full written report (outputs to session/post-mortem.json)

Analysis includes:
  - What caused BLOCKED (score < 50? retry >= 3?)
  - Agent that was active
  - Decision chain leading up to it
  - Recommendations to prevent recurrence

EOF
    exit 0
}

SESSION_ID=""
MODE="quick"
JSON="false"
VERBOSE="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --session) SESSION_ID="$2"; shift ;;
        --mode) MODE="$2"; shift ;;
        --json) JSON="true" ;;
        --verbose) VERBOSE="true" ;;
        --help|-h) usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
    shift
done

# Auto-detect session
if [[ -z "$SESSION_ID" ]]; then
    SESSION_ID="session"
fi

analyze_quick() {
    local contract_file="session/contract.json"
    
    if [[ ! -f "$contract_file" ]]; then
        log_info "No contract found at $contract_file"
        return 1
    fi
    
    local state=$(jq -r '.state // "UNKNOWN"' "$contract_file")
    if [[ "$state" != "BLOCKED" ]]; then
        log_info "Session $SESSION_ID is not BLOCKED (state: $state)"
        return 0
    fi
    
    log_info "=== BLOCKED Post-Mortem ($SESSION_ID) ==="
    
    local score=$(jq -r '.score // 0' "$contract_file")
    local retries=$(jq -r '.retries // 0' "$contract_file")
    local agent=$(jq -r '.orchestration_contract.planning.primary_agent // "unknown"' "$contract_file" 2>/dev/null || echo "unknown")
    local phase=$(jq -r '.orchestration_contract.planning.current_phase // "unknown"' "$contract_file" 2>/dev/null || echo "unknown")
    
    # Determine cause
    local cause=""
    if [[ $score -lt 50 ]]; then
        cause="SCORE_TOO_LOW"
        log_fail "Cause: Score below threshold ($score < 50)"
    elif [[ $retries -ge 3 ]]; then
        cause="MAX_RETRIES_EXHAUSTED"
        log_fail "Cause: Max retries exhausted ($retries >= 3)"
    else
        cause="UNKNOWN"
        log_info "Cause: Unknown (score=$score, retries=$retries)"
    fi
    
    log_info "Agent: $agent | Phase: $phase | Score: $score | Retries: $retries"
    
    # Recommendations
    log_info "=== Recommendations ==="
    case "$cause" in
        SCORE_TOO_LOW)
            log_info "1. Review agent capabilities for $agent"
            log_info "2. Check if planning phase had sufficient context"
            log_info "3. Consider lowering min_score in rules.json"
            ;;
        MAX_RETRIES_EXHAUSTED)
            log_info "1. Investigate root cause of repeated failures"
            log_info "2. Check MCP server health (mcp-health.sh)"
            log_info "3. Consider increasing max_retries in rules.json"
            ;;
    esac
    
    if [[ "$JSON" == "true" ]]; then
        jq -n --arg br "$SESSION_ID" --arg cause "$cause" --arg agent "$agent" \
            '{session:$br, cause:$cause, agent:$agent, score:$score, retries:$retries}'
    fi
}

analyze_deep() {
    log_info "=== Deep Post-Mortem ==="

    local state_file="session/state.md"
    local blocked_count=0
    local rows=""

    if [[ -f "$state_file" ]]; then
        while IFS='|' read -r _ ts sess st sc _hash _rest; do
            ts="$(echo "$ts" | xargs)"; sess="$(echo "$sess" | xargs)"
            st="$(echo "$st" | xargs)"; sc="$(echo "$sc" | xargs)"
            [[ "$ts" == "Timestamp" || -z "$st" ]] && continue
            if [[ "$st" == "BLOCKED" ]]; then
                rows+="$ts|$sess|$sc"$'\n'
                blocked_count=$((blocked_count + 1))
            fi
        done < "$state_file"
    fi

    log_info "Found $blocked_count BLOCKED transitions in session history"

    if [[ -n "$rows" ]]; then
        while IFS='|' read -r ts sess sc; do
            [[ -z "$ts" ]] && continue
            log_info "  $ts | $sess | score=$sc"
        done <<< "$rows"
    fi

    if [[ "$JSON" == "true" ]]; then
        local arr="[]"
        [[ -n "$rows" ]] && arr=$(printf '%s' "$rows" | grep -v '^$' | jq -R -s 'split("\n") | map(select(length>0))')
        jq -n --argjson c "$blocked_count" --argjson s "$arr" '{blocked_count:$c, transitions:$s}'
    fi
}

analyze_report() {
    local output_file="session/post-mortem.json"
    
    analyze_quick > /tmp/post-mortem-quick.txt
    
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local cause=$(grep "Cause:" /tmp/post-mortem-quick.txt | head -1)
    local agent=$(grep "Agent:" /tmp/post-mortem-quick.txt | head -1)
    local recommendations=$(grep -A3 "Recommendations" /tmp/post-mortem-quick.txt)
    
    jq -n --arg ts "$timestamp" --arg br "$SESSION_ID" \
        '{timestamp:$ts, session:$br, analysis:"see quick output", status:"generated"}' > "$output_file"
    
    log_pass "Post-mortem report saved to $output_file"
}

main() {
    case "$MODE" in
        quick) analyze_quick ;;
        deep) analyze_deep ;;
        report) analyze_report ;;
        *) echo "Unknown mode: $MODE" >&2; exit 1 ;;
    esac
}

main