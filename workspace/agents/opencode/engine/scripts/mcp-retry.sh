#!/usr/bin/env bash
# mcp-retry.sh — Auto-retry with exponential backoff for MCP operations
# Usage: scripts/mcp-retry.sh --command C [--max-retries N] [--base-delay S] [--timeout S]
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

CIRCUIT_FILE="/tmp/.mcp_circuit_breaker"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --command C       Command to retry (required)
  --max-retries N   Max retry attempts (default: 3)
  --base-delay S    Initial delay seconds (default: 2)
  --max-delay S     Max delay cap (default: 60)
  --backoff STR     LINEAR|EXPONENTIAL|FIBONACCI (default: EXPONENTIAL)
  --timeout S       Per-attempt timeout (default: 30)
  --jitter BOOL     Add ±25% jitter (default: true)
  --circuit N       Trips after N consecutive failures (default: 5)
  --cooldown S      Circuit breaker cooldown seconds (default: 300)
  --status          Check circuit breaker status
  --dry-run         Preview without executing
  --verbose         Verbose output

EOF
    exit 0
}

COMMAND=""
MAX_RETRIES=3
BASE_DELAY=2
MAX_DELAY=60
BACKOFF="EXPONENTIAL"
TIMEOUT=30
JITTER="true"
CIRCUIT_THRESHOLD=5
COOLDOWN=300
STATUS="false"
DRY_RUN="false"
VERBOSE="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --command) COMMAND="$2"; shift ;;
        --max-retries) MAX_RETRIES="$2"; shift ;;
        --base-delay) BASE_DELAY="$2"; shift ;;
        --max-delay) MAX_DELAY="$2"; shift ;;
        --backoff) BACKOFF="$2"; shift ;;
        --timeout) TIMEOUT="$2"; shift ;;
        --jitter) JITTER="$2"; shift ;;
        --circuit) CIRCUIT_THRESHOLD="$2"; shift ;;
        --cooldown) COOLDOWN="$2"; shift ;;
        --status) STATUS="true" ;;
        --dry-run) DRY_RUN="true" ;;
        --verbose) VERBOSE="true" ;;
        --help|-h) usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
    shift
done

get_delay() {
    local attempt="$1"
    local delay=0
    
    case "$BACKOFF" in
        LINEAR)
            delay=$((BASE_DELAY * attempt))
            ;;
        EXPONENTIAL)
            delay=$((BASE_DELAY * (2 ** (attempt - 1))))
            ;;
        FIBONACCI)
            local fib=(1 1 2 3 5 8 13 21)
            [[ $attempt -gt ${#fib[@]} ]] && attempt=${#fib[@]}
            delay=$((BASE_DELAY * fib[attempt - 1]))
            ;;
    esac
    
    [[ $delay -gt $MAX_DELAY ]] && delay=$MAX_DELAY
    
    if [[ "$JITTER" == "true" ]]; then
        local jitter=$((RANDOM % (delay / 2)))
        [[ $RANDOM -gt 16384 ]] && delay=$((delay + jitter)) || delay=$((delay - jitter))
    fi
    
    echo $delay
}

check_circuit() {
    if [[ -f "$CIRCUIT_FILE" ]]; then
        local circuit_data=$(cat "$CIRCUIT_FILE")
        local failures=$(echo "$circuit_data" | cut -d'|' -f1)
        local last_failure=$(echo "$circuit_data" | cut -d'|' -f2)
        local now=$(date +%s)
        
        if [[ $failures -ge $CIRCUIT_THRESHOLD ]]; then
            local elapsed=$((now - last_failure))
            if [[ $elapsed -lt $COOLDOWN ]]; then
                echo "OPEN"
                return
            fi
        fi
    fi
    echo "CLOSED"
}

record_failure() {
    local failures=0
    if [[ -f "$CIRCUIT_FILE" ]]; then
        failures=$(cut -d'|' -f1 "$CIRCUIT_FILE")
    fi
    failures=$((failures + 1))
    echo "$failures|$(date +%s)" > "$CIRCUIT_FILE"
}

record_success() {
    echo "0|$(date +%s)" > "$CIRCUIT_FILE"
}

show_status() {
    local state=$(check_circuit)
    local failures=0
    local last_failure=""
    
    if [[ -f "$CIRCUIT_FILE" ]]; then
        failures=$(cut -d'|' -f1 "$CIRCUIT_FILE")
        last_failure=$(cut -d'|' -f2 "$CIRCUIT_FILE")
    fi
    
    log_info "=== Circuit Breaker Status ==="
    printf "  State:        %s\n" "$state"
    printf "  Failures:     %d\n" $failures
    printf "  Threshold:    %d\n" $CIRCUIT_THRESHOLD
    printf "  Cooldown:     %ds\n" $COOLDOWN
    [[ -n "$last_failure" ]] && printf "  Last failure: %s\n" "$(date -d @$last_failure)"
}

run_with_retry() {
    local circuit=$(check_circuit)
    if [[ "$circuit" == "OPEN" ]]; then
        log_fail "Circuit breaker OPEN — skipping retry"
        exit 2
    fi
    
    for attempt in $(seq 1 $MAX_RETRIES); do
        log_verbose "Attempt $attempt of $MAX_RETRIES"
        
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[DRY_RUN] Would execute: $COMMAND"
            exit 0
        fi
        
        local start=$(date +%s%N)
        if timeout "$TIMEOUT" bash -c "$COMMAND" 2>/dev/null; then
            local elapsed=$(( ($(date +%s%N) - start) / 1000000 ))
            record_success
            log_pass "Success on attempt $attempt (elapsed: ${elapsed}ms)"
            exit 0
        fi
        
        local delay=$(get_delay $attempt)
        log_fail "Attempt $attempt failed — retrying in ${delay}s..."
        record_failure
        sleep $delay
    done
    
    log_fail "All $MAX_RETRIES attempts failed"
    exit 1
}

if [[ "$STATUS" == "true" ]]; then
    show_status
    exit 0
fi

if [[ -z "$COMMAND" ]]; then
    echo "ERROR: --command required" >&2
    usage
fi

run_with_retry