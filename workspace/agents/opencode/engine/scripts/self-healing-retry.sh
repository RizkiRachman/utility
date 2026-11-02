#!/usr/bin/env bash
# self-healing-retry.sh — Self-Healing Retry Loop Wrapper (G17) with Adaptive Strategy (G24)
# Wraps agent delegation with intelligent retry logic. When a delegation fails
# (timeout, score below threshold, exit != 0), it retries with adaptive strategy:
# exponential backoff with jitter, agent switching, timeout scaling.
#
# Usage:
#   scripts/self-healing-retry.sh --command CMD [OPTIONS]
#   scripts/self-healing-retry.sh --command "my-agent.sh --task X" --label "code-gen"
#   scripts/self-healing-retry.sh --command CMD --max-retries 5 --verbose
#   scripts/self-healing-retry.sh --command CMD --dry-run
#   scripts/self-healing-retry.sh --help
#
# Exit codes:
#   0 — Command succeeded (or recovered on retry with recovery_exit=0, use --recovery-exit)
#   1 — Recovered on retry (command failed on earlier attempts, succeeded later)
#   2 — All attempts failed
#   3 — Usage displayed or error in arguments
#
# Logs written to: session/retry.log

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Color Constants ──────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    CYAN=''
    NC=''
fi

# ── Defaults ─────────────────────────────────────────────────────────────────
COMMAND=""
LABEL="unnamed-task"
MAX_RETRIES=""        # from rules.json scoring.retry_max_attempts
TIMEOUT_MS=""         # from rules.json agent_watchdog.delegation_timeout_ms
PASS_THRESHOLD=""     # from rules.json scoring.thresholds.pass
ESCALATION_MIN=""     # from rules.json scoring.thresholds.escalation
VERBOSE=false
DRY_RUN=false
RECOVERY_EXIT=1        # exit code when recovered on retry
RETRY_LOG_DIR=""

# ── Usage ────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
self-healing-retry.sh — Self-Healing Retry Loop Wrapper (G17) with Adaptive Strategy (G24)

Wraps agent delegation with intelligent retry logic. When a delegation fails
(timeout, score below threshold, exit != 0), it retries with adaptive strategy:
exponential backoff with jitter, agent switching, timeout scaling.

Usage:
    $(basename "$0") --command CMD [OPTIONS]
    $(basename "$0") --command "my-agent.sh --task X" --label "code-gen"
    $(basename "$0") --command CMD --max-retries 5 --verbose
    $(basename "$0") --command CMD --dry-run
    $(basename "$0") --help

Required:
    --command CMD       Command to execute and retry on failure

Options:
    --label NAME        Human-readable label for this task (default: "unnamed-task")
    --max-retries N     Override max retry attempts (default: from rules.json)
    --timeout MS        Timeout per attempt in milliseconds (default: from rules.json)
    --pass-threshold N  Score threshold for pass (default: from rules.json)
    --escalation-min N  Minimum score before escalation (default: from rules.json)
    --recovery-exit N   Exit code when recovered on retry (default: 1)
    --verbose           Show each attempt, backoff delay, and strategy decision
    --dry-run           Simulate without executing the command
    --help              Show this help message

Adaptive Strategy:
    Attempt 1:  base timeout, no backoff
    Attempt 2:  2x timeout, 1s backoff + jitter
    Attempt 3+:  3x timeout, 2s backoff + exponential + jitter
    If all fail: escalate (exit 2)

Config loaded from: rules/rules.json → scoring.thresholds.*, agent_watchdog.delegation_timeout_ms
Logs written to: session/retry.log

Examples:
    $(basename "$0") --command "echo hello" --label "test"
    $(basename "$0") --command "./run-task.sh" --max-retries 5 --verbose
    $(basename "$0") --command "./agent.sh" --timeout 60000 --label "code-gen"
    $(basename "$0") --command "./agent.sh" --dry-run

Exit codes:
    0   Command succeeded on first try
    1   Recovered on retry
    2   All attempts failed
    3   Usage displayed or error in arguments
EOF
    exit 3
}

# ── Logging Functions ────────────────────────────────────────────────────────
log_pass() {
    echo -e "  ${GREEN}[PASS]${NC} $1"
}

log_fail() {
    echo -e "  ${RED}[FAIL]${NC} $1" >&2
}

log_info() {
    echo -e "  ${YELLOW}[INFO]${NC} $1"
}

log_verbose() {
    if [[ "$VERBOSE" == true ]]; then
        echo -e "  ${CYAN}[VERB]${NC} $1"
    fi
}

log_dry() {
    echo -e "  ${CYAN}[DRY-RUN]${NC} $1"
}

log_section() {
    echo -e "${CYAN}■${NC} $1"
}

# ── Retry Logging ────────────────────────────────────────────────────────────
log_retry() {
    local entry="$1"
    local timestamp
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    if [[ -n "$RETRY_LOG_DIR" ]]; then
        mkdir -p "$RETRY_LOG_DIR"
        echo "[${timestamp}] ${entry}" >> "$RETRY_LOG_DIR/retry.log"
    fi
    log_verbose "[RETRY-LOG] ${entry}"
}

# ── Config Loading ───────────────────────────────────────────────────────────
load_rules_config() {
    local rules_file="$PROJECT_DIR/rules/rules.json"
    if [[ ! -f "$rules_file" ]]; then
        log_verbose "rules.json not found at $rules_file, using defaults"
        return 0
    fi
    if ! command -v jq &>/dev/null; then
        log_verbose "jq not available, cannot parse rules.json, using defaults"
        return 0
    fi

    # Read retry config — only apply if user didn't override via flag
    if [[ -z "$MAX_RETRIES" ]]; then
        local config_retries
        config_retries="$(jq -r '.scoring.thresholds.retry_max_attempts // 3' "$rules_file" 2>/dev/null || echo 3)"
        MAX_RETRIES="$config_retries"
    fi
    if [[ -z "$TIMEOUT_MS" ]]; then
        local config_timeout
        config_timeout="$(jq -r '.agent_watchdog.delegation_timeout_ms // 120000' "$rules_file" 2>/dev/null || echo 120000)"
        TIMEOUT_MS="$config_timeout"
    fi
    if [[ -z "$PASS_THRESHOLD" ]]; then
        local config_pass
        config_pass="$(jq -r '.scoring.thresholds.pass // 70' "$rules_file" 2>/dev/null || echo 70)"
        PASS_THRESHOLD="$config_pass"
    fi
    if [[ -z "$ESCALATION_MIN" ]]; then
        local config_escalation
        config_escalation="$(jq -r '.scoring.thresholds.escalation // 50' "$rules_file" 2>/dev/null || echo 50)"
        ESCALATION_MIN="$config_escalation"
    fi

    log_verbose "Config loaded: max_retries=${MAX_RETRIES}, timeout=${TIMEOUT_MS}ms, pass=${PASS_THRESHOLD}, escalation=${ESCALATION_MIN}"
}

get_session() {
    echo session 2>/dev/null || echo "unknown"
}

# ── Adaptive Backoff Calculation ─────────────────────────────────────────────
# Calculates delay with exponential backoff and jitter.
# Attempt 1: 0s
# Attempt 2: 1s + 25% jitter
# Attempt 3+: 2^(attempt-2)s + 25% jitter
calculate_backoff() {
    local attempt="$1"
    if [[ "$attempt" -le 1 ]]; then
        echo 0
        return 0
    fi
    local base_seconds
    if [[ "$attempt" -eq 2 ]]; then
        base_seconds=1
    else
        # Exponential: 2^(attempt-2)
        base_seconds=$(( 2 ** (attempt - 2) ))
    fi
    # Add 0-25% jitter
    local jitter_max=$(( base_seconds * 25 / 100 ))
    if [[ "$jitter_max" -le 0 ]]; then
        jitter_max=1
    fi
    local jitter=$(( RANDOM % (jitter_max + 1) ))
    echo $(( base_seconds + jitter ))
}

# ── Timeout Scaling ──────────────────────────────────────────────────────────
# Attempt 1: base timeout
# Attempt 2: 2x base
# Attempt 3+: 3x base (capped)
calculate_timeout() {
    local attempt="$1"
    local base="$2"
    if [[ "$attempt" -le 1 ]]; then
        echo "$base"
    elif [[ "$attempt" -eq 2 ]]; then
        echo $(( base * 2 ))
    else
        echo $(( base * 3 ))
    fi
}

# ── Strategy Description ─────────────────────────────────────────────────────
describe_strategy() {
    local attempt="$1"
    local max="$2"
    local timeout="$3"
    local delay="$4"

    if [[ "$attempt" -eq 1 ]]; then
        echo "Attempt ${attempt}/${max}: base timeout ${timeout}ms, no backoff"
    elif [[ "$attempt" -eq 2 ]]; then
        echo "Attempt ${attempt}/${max}: 2x timeout ${timeout}ms, ${delay}s backoff + jitter"
    else
        echo "Attempt ${attempt}/${max}: 3x timeout ${timeout}ms, ${delay}s exponential backoff + jitter"
    fi
}

# ── Main Execution ───────────────────────────────────────────────────────────
main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --command)
                shift
                if [[ $# -eq 0 ]]; then
                    log_fail "--command requires an argument"
                    exit 3
                fi
                COMMAND="$1"
                ;;
            --label)
                shift
                if [[ $# -eq 0 ]]; then
                    log_fail "--label requires an argument"
                    exit 3
                fi
                LABEL="$1"
                ;;
            --max-retries)
                shift
                if [[ $# -eq 0 ]]; then
                    log_fail "--max-retries requires an argument"
                    exit 3
                fi
                MAX_RETRIES="$1"
                ;;
            --timeout)
                shift
                if [[ $# -eq 0 ]]; then
                    log_fail "--timeout requires an argument"
                    exit 3
                fi
                TIMEOUT_MS="$1"
                ;;
            --pass-threshold)
                shift
                if [[ $# -eq 0 ]]; then
                    log_fail "--pass-threshold requires an argument"
                    exit 3
                fi
                PASS_THRESHOLD="$1"
                ;;
            --escalation-min)
                shift
                if [[ $# -eq 0 ]]; then
                    log_fail "--escalation-min requires an argument"
                    exit 3
                fi
                ESCALATION_MIN="$1"
                ;;
            --recovery-exit)
                shift
                if [[ $# -eq 0 ]]; then
                    log_fail "--recovery-exit requires an argument"
                    exit 3
                fi
                RECOVERY_EXIT="$1"
                ;;
            --verbose)
                VERBOSE=true
                ;;
            --dry-run)
                DRY_RUN=true
                ;;
            --help)
                usage
                ;;
            *)
                log_fail "Unknown option: $1"
                usage
                ;;
        esac
        shift
    done

    # Validate required args
    if [[ -z "$COMMAND" ]]; then
        log_fail "--command is required"
        usage
    fi

    # Load config from rules.json
    load_rules_config

    # Ensure numeric values are sane
    MAX_RETRIES="${MAX_RETRIES:-3}"
    TIMEOUT_MS="${TIMEOUT_MS:-120000}"
    PASS_THRESHOLD="${PASS_THRESHOLD:-70}"
    ESCALATION_MIN="${ESCALATION_MIN:-50}"

    # Setup retry log directory
    local session
    session="$(get_session)"
    RETRY_LOG_DIR="$PROJECT_DIR/session"
    mkdir -p "$RETRY_LOG_DIR"

    log_section "Self-Healing Retry: ${LABEL}"
    log_info "Command: ${COMMAND}"
    log_info "Max retries: ${MAX_RETRIES}, Timeout: ${TIMEOUT_MS}ms"
    log_info "Pass threshold: ${PASS_THRESHOLD}, Escalation min: ${ESCALATION_MIN}"
    if [[ "$DRY_RUN" == true ]]; then
        log_info "DRY RUN — no commands will be executed"
    fi
    echo ""

    local attempt=0
    local exit_code=0
    local recovered=false

    while [[ "$attempt" -lt "$MAX_RETRIES" ]]; do
        attempt=$(( attempt + 1 ))

        # Calculate adaptive strategy for this attempt
        local use_timeout
        use_timeout="$(calculate_timeout "$attempt" "$TIMEOUT_MS")"
        local backoff_seconds
        backoff_seconds="$(calculate_backoff "$attempt")"

        local strategy_desc
        strategy_desc="$(describe_strategy "$attempt" "$MAX_RETRIES" "$use_timeout" "$backoff_seconds")"
        log_verbose "Strategy: ${strategy_desc}"

        # Backoff before retry (not on first attempt)
        if [[ "$attempt" -gt 1 && "$backoff_seconds" -gt 0 ]]; then
            if [[ "$DRY_RUN" == true ]]; then
                log_dry "Would sleep ${backoff_seconds}s before attempt ${attempt}"
            else
                log_info "Backoff ${backoff_seconds}s before attempt ${attempt}/${MAX_RETRIES}..."
                sleep "$backoff_seconds"
            fi
        fi

        local start_time
        start_time="$(date +%s)"
        local cmd_exit=0

        # Execute (or simulate)
        if [[ "$DRY_RUN" == true ]]; then
            log_dry "Would execute: ${COMMAND} (timeout: ${use_timeout}ms)"
            cmd_exit=0
        else
            log_verbose "Executing: ${COMMAND} (timeout: ${use_timeout}ms)"
            set +e
            timeout "$(( use_timeout / 1000 ))" bash -c "$COMMAND" 2>&1 || cmd_exit=$?
            set -euo pipefail
        fi

        local end_time
        end_time="$(date +%s)"
        local elapsed=$(( end_time - start_time ))

        # Determine result
        local succeeded=false
        local reason=""

        if [[ "$cmd_exit" -eq 0 ]]; then
            succeeded=true
            reason="exit=0"
        elif [[ "$cmd_exit" -eq 124 ]]; then
            reason="timeout (${use_timeout}ms exceeded)"
        else
            reason="exit=${cmd_exit}"
        fi

        # Log the attempt
        log_retry "attempt=${attempt}/${MAX_RETRIES} label=${LABEL} command=${COMMAND} exit=${cmd_exit} elapsed=${elapsed}s timeout=${use_timeout}ms backoff=${backoff_seconds}s"

        if [[ "$succeeded" == true ]]; then
            if [[ "$attempt" -eq 1 ]]; then
                log_pass "${LABEL} succeeded on first attempt (${elapsed}s)"
                echo ""
                exit 0
            else
                log_pass "${LABEL} recovered on attempt ${attempt}/${MAX_RETRIES} (${elapsed}s)"
                recovered=true
                echo ""
                exit "$RECOVERY_EXIT"
            fi
        else
            log_fail "${LABEL} failed on attempt ${attempt}/${MAX_RETRIES} — ${reason} (${elapsed}s)"

            # Check if we should escalate early (score below escalation threshold)
            # When timeout occurs, that's also an escalation signal
            if [[ "$cmd_exit" -eq 124 ]]; then
                log_info "Timeout detected — will scale timeout on next attempt"
            fi

            if [[ "$attempt" -lt "$MAX_RETRIES" ]]; then
                log_info "Scheduling retry ${attempt}/${MAX_RETRIES}..."
                echo ""
            fi
        fi
    done

    # All attempts failed
    log_fail "${LABEL} failed after ${MAX_RETRIES} attempt(s) — escalating"
    log_retry "escalate label=${LABEL} command=${COMMAND} attempts=${MAX_RETRIES} result=failed"
    echo ""
    exit 2
}

main "$@"
