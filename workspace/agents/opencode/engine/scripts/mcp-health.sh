#!/usr/bin/env bash
# mcp-health.sh — Health check endpoint for MCP servers
# Usage: scripts/mcp-health.sh [--check TYPE] [--timeout S] [--json] [--continuous] [--interval S] [--max-iterations N]
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
  --check TYPE      mcp|api|all (default: all)
  --timeout S       Per-check timeout (default: 10)
  --json            Machine-readable output
  --continuous      Watch mode (poll every N seconds)
  --interval S      Poll interval (default: 60)
  --alert P         Alert if failure % exceeds P (default: 20)
  --verbose         Verbose output

Checks:
  mcp   — graphify-mcp process + graph.json, lean-ctx MCP
  api   — sumopod API connectivity
  all   — all checks

EOF
    exit 0
}

CHECK="all"
TIMEOUT=10
JSON="false"
CONTINUOUS="false"
MAX_ITERATIONS=120  # N5: bound continuous mode (2h at 60s interval)
ITER=0
INTERVAL=60
ALERT_THRESHOLD=20
VERBOSE="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check) CHECK="$2"; shift ;;
        --timeout) TIMEOUT="$2"; shift ;;
        --json) JSON="true" ;;
        --continuous) CONTINUOUS="true" ;;
        --max-iterations) MAX_ITERATIONS="$2"; shift 2 ;;
        --interval) INTERVAL="$2"; shift ;;
        --alert) ALERT_THRESHOLD="$2"; shift ;;
        --verbose) VERBOSE="true" ;;
        --help|-h) usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
    shift
done

check_graphify() {
    local status="PASS"
    local latency=0
    local start=$(date +%s%N)
    
    # Check graphify-mcp binary exists
    if ! command -v graphify-mcp &>/dev/null; then
        status="FAIL"
        log_fail "graphify-mcp binary not found"
    fi
    
    # Check graph.json exists
    if [[ ! -f "graphify-out/graph.json" ]]; then
        status="FAIL"
        log_fail "graphify-out/graph.json missing"
    fi
    
    # Quick test call
    if timeout $TIMEOUT graphify graph_stats &>/dev/null; then
        log_pass "graphify-mcp responsive"
    else
        status="FAIL"
        log_fail "graphify-mcp timed out"
    fi
    
    latency=$(( ($(date +%s%N) - start) / 1000000 ))
    echo "graphify|$status|$latency"
}

check_lean-ctx() {
    local status="PASS"
    local latency=0
    local start=$(date +%s%N)
    
    if ! command -v lean-ctx &>/dev/null; then
        status="FAIL"
        log_fail "lean-ctx binary not found"
    elif timeout $TIMEOUT lean-ctx list_repos &>/dev/null; then
        log_pass "lean-ctx MCP responsive"
    else
        status="WARN"
        log_fail "lean-ctx timed out"
    fi
    
    latency=$(( ($(date +%s%N) - start) / 1000000 ))
    echo "lean-ctx|$status|$latency"
}

check_sumopod() {
    local status="PASS"
    local latency=0
    local start=$(date +%s%N)
    
    # Check if OPENAI_API_KEY is set from sumopod config
    local api_key=$(jq -r '.provider.semutssh.options.apiKey // empty' opencode.json 2>/dev/null || echo "")
    local base_url=$(jq -r '.provider.semutssh.options.baseURL // empty' opencode.json 2>/dev/null || echo "")
    
    if [[ -z "$api_key" || -z "$base_url" ]]; then
        status="WARN"
        log_info "sumopod config not found in opencode.json"
    else
        if timeout $TIMEOUT curl -sf "$base_url/v1/models" -H "Authorization: Bearer $api_key" &>/dev/null; then
            log_pass "sumopod API responsive ($base_url)"
        else
            status="FAIL"
            log_fail "sumopod API unreachable ($base_url)"
        fi
    fi
    
    latency=$(( ($(date +%s%N) - start) / 1000000 ))
    echo "sumopod|$status|$latency"
}

run_checks() {
    local results=""
    
    case "$CHECK" in
        mcp)
            results+="$(check_graphify)\n"
            results+="$(check_lean-ctx)\n"
            ;;
        api)
            results+="$(check_sumopod)\n"
            ;;
        all)
            results+="$(check_graphify)\n"
            results+="$(check_lean-ctx)\n"
            results+="$(check_sumopod)\n"
            ;;
    esac
    
    if [[ "$JSON" == "true" ]]; then
        echo "$results" | while IFS='|' read -r name status latency; do
            echo "{\"name\":\"$name\",\"status\":\"$status\",\"latency_ms\":$latency}"
        done | jq -s '.'
    else
        log_info "=== MCP Health Check ==="
        echo "$results" | while IFS='|' read -r name status latency; do
            printf "  %-12s | %-4s | %dms\n" "$name" "$status" "$latency"
        done
    fi
    
    # Alert if failure rate exceeds threshold
    local failures=$(echo "$results" | grep -c 'FAIL' || echo "0")
    local total=$(echo "$results" | wc -l | tr -d ' ')
    local pct=$((failures * 100 / total))
    if [[ $pct -ge $ALERT_THRESHOLD ]]; then
        log_fail "ALERT: $pct% checks failing (threshold: $ALERT_THRESHOLD%)"
        exit 1
    fi
}

if [[ "$CONTINUOUS" == "true" ]]; then
    log_info "Starting continuous health monitoring (interval: $INTERVALs)"
    while true; do
        ITER=$((ITER + 1))
        if (( ITER > MAX_ITERATIONS )); then log_info "Reached max iterations ($MAX_ITERATIONS), stopping"; break; fi
        echo "=== $(date) ==="
        run_checks
        sleep $INTERVAL
    done
else
    run_checks
fi