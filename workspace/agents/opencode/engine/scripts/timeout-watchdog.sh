#!/usr/bin/env bash
# timeout-watchdog.sh — Timer-Based Delegation Watchdog (G19)
# Monitors a running agent process and kills it if it exceeds the timeout.
# Detects deadlock patterns in child processes.
#
# Usage:
#   scripts/timeout-watchdog.sh --watch PID                 # Monitor by PID
#   scripts/timeout-watchdog.sh --watch PID --label "my-agent"
#   scripts/timeout-watchdog.sh --watch PID --timeout 30000 --notify
#   scripts/timeout-watchdog.sh --watch PID --poll 2 --verbose
#   scripts/timeout-watchdog.sh --help
#
# Exit codes:
#   0 — Process completed successfully within timeout
#   1 — Process timed out (SIGTERM sent) or deadlock detected
#   2 — Error (missing args, invalid PID, etc.)
#
# Logs written to: session/watchdog.log

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/paths.sh"  # N1: session state lives with the project
PROJECT_DIR="$(resolve_project_root "${SCRIPT_DIR}/..")"

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ── Defaults ────────────────────────────────────────────────────────────────
WATCH_PID=""
TIMEOUT_MS=""
LABEL="unnamed-process"
ENABLE_NOTIFY=false
POLL_FREQ=5
OUTPUT_DIR=""
DRY_RUN=false
VERBOSE=false
HELP=false
DEADLOCK_THRESHOLD=3  # consecutive polling cycles with all children in sleep

# Will be resolved
TIMEOUT_SEC=""
LOG_FILE=""

# ── Usage ───────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Timer-based delegation watchdog — monitors a running process and terminates
it if it exceeds the configured timeout. Detects deadlock patterns in child
processes.

Options:
  --watch PID         PID of the process to monitor (required)
  --timeout MS        Timeout in milliseconds (default: 120000, from rules.json)
  --label NAME        Human-readable label for the process (default: "unnamed")
  --notify            Send desktop notification on timeout
  --poll FREQ         Check frequency in seconds (default: 5)
  --output-dir DIR    Directory for watchdog logs (default: session/)
  --dry-run           Preview without sending signals
  --verbose           Show detailed status at each poll
  --help              Show this help message and exit

Exit codes:
  0   Process completed within timeout
  1   Process timed out or deadlock detected
  2   Error (missing args, invalid PID, etc.)

Config loaded from: rules/rules.json → agent_watchdog.delegation_timeout_ms
  Logs written to: <output-dir>/watchdog.log

Examples:
  $(basename "$0") --watch 12345
  $(basename "$0") --watch 12345 --timeout 60000 --label "code-gen"
  $(basename "$0") --watch 12345 --notify --verbose

EOF
    exit 0
}

# ── Logging helpers ─────────────────────────────────────────────────────────
# log_pass/log_fail/log_info/log_verbose come from scripts/lib.

log_section() {
    echo ""
    echo -e "${CYAN}■${NC} $1"
}

# ════════════════════════════════════════════════════════════════════════════
# Watchdog Logging
# ════════════════════════════════════════════════════════════════════════════

watchdog_log() {
    local entry="$1"
    local timestamp
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    if [[ -n "$LOG_FILE" ]]; then
        local log_dir
        log_dir="$(dirname "$LOG_FILE")"
        mkdir -p "$log_dir"
        echo "[${timestamp}] ${entry}" >> "$LOG_FILE"
    fi
    log_verbose "[LOG] ${entry}"
}

# ════════════════════════════════════════════════════════════════════════════
# Desktop Notification
# ════════════════════════════════════════════════════════════════════════════

send_notify() {
    local title="$1"
    local message="$2"

    if [[ "$ENABLE_NOTIFY" == false ]]; then
        return 0
    fi

    # macOS (osascript)
    if command -v osascript &>/dev/null; then
        osascript -e "display notification \"${message}\" with title \"${title}\"" 2>/dev/null || true
        return 0
    fi

    # Linux (notify-send)
    if command -v notify-send &>/dev/null; then
        notify-send "${title}" "${message}" 2>/dev/null || true
        return 0
    fi

    # Fallback: terminal bell
    echo -e "\a" >&2
    log_info "Desktop notification not available, used terminal bell."
}

# ════════════════════════════════════════════════════════════════════════════
# Config Loading
# ════════════════════════════════════════════════════════════════════════════

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

    local config_timeout
    config_timeout="$(jq -r '.agent_watchdog.delegation_timeout_ms // 120000' "$rules_file" 2>/dev/null || echo 120000)"

    # Only use config value if user didn't specify --timeout
    if [[ -z "$TIMEOUT_MS" ]]; then
        TIMEOUT_MS="$config_timeout"
    fi

    local config_deadlock
    config_deadlock="$(jq -r '.agent_watchdog.deadlock_detection.max_wait_cycles // 5' "$rules_file" 2>/dev/null || echo 5)"
    DEADLOCK_THRESHOLD="$config_deadlock"

    log_verbose "Config: timeout=${TIMEOUT_MS}ms, deadlock_threshold=${DEADLOCK_THRESHOLD}"
}

# ════════════════════════════════════════════════════════════════════════════
# ════════════════════════════════════════════════════════════════════════════

get_session() {
    echo session 2>/dev/null || echo "unknown"
}

# ════════════════════════════════════════════════════════════════════════════
# Process Utilities
# ════════════════════════════════════════════════════════════════════════════

# Check if a process is still running
is_process_running() {
    local pid="$1"
    kill -0 "$pid" 2>/dev/null
}

# Get all child PIDs (recursive) for a given parent PID
get_children_recursive() {
    local pid="$1"
    # macOS-compatible: use pgrep -P which exists on both
    pgrep -P "$pid" 2>/dev/null || true
}

# Check if all children are in uninterruptible sleep (deadlock indicator)
# macOS: use `ps -o state` or `ps -o s` to get process state
check_deadlock() {
    local pid="$1"
    local children
    children="$(get_children_recursive "$pid")"

    if [[ -z "$children" ]]; then
        # No children — can't deadlock
        echo "no_children"
        return 0
    fi

    local all_sleep=true
    local child_count=0
    local sleep_count=0

    while IFS= read -r child_pid; do
        [[ -z "$child_pid" ]] && continue
        child_count=$((child_count + 1))

        # Get process state (single character: R=running, S=sleeping, D=disk sleep, Z=zombie)
        local state
        state="$(ps -o state= -p "$child_pid" 2>/dev/null || echo "?")"
        state="${state:0:1}"

        # S=sleeping (interruptible), D=uninterruptible sleep (disk I/O wait)
        if [[ "$state" == "S" || "$state" == "D" ]]; then
            sleep_count=$((sleep_count + 1))
        else
            all_sleep=false
        fi

        log_verbose "  child $child_pid state=$state"
    done <<< "$children"

    if [[ "$child_count" -eq 0 ]]; then
        echo "no_children"
        return 0
    fi

    if [[ "$all_sleep" == true ]] && [[ "$sleep_count" -gt 0 ]]; then
        echo "all_sleep"
    else
        echo "active"
    fi
}

# Send SIGTERM, wait, then SIGKILL if still alive
terminate_process() {
    local pid="$1"
    local label="$2"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would send SIGTERM to PID ${pid} (${label})"
        return 0
    fi

    log_info "Sending SIGTERM to PID ${pid} (${label})..."
    kill -TERM "$pid" 2>/dev/null || true

    # Wait 3 seconds for graceful shutdown
    sleep 3

    if is_process_running "$pid"; then
        log_info "Process still running, sending SIGKILL to PID ${pid}..."
        kill -KILL "$pid" 2>/dev/null || true
        sleep 1
        if is_process_running "$pid"; then
            log_fail "Could not terminate PID ${pid} even with SIGKILL."
        fi
    fi
}

# ════════════════════════════════════════════════════════════════════════════
# Main Watchdog Loop
# ════════════════════════════════════════════════════════════════════════════

run_watchdog() {
    local pid="$WATCH_PID"
    local label="$LABEL"
    local timeout_sec="$TIMEOUT_SEC"
    local poll_freq="$POLL_FREQ"
    local elapsed=0
    local deadlock_cycles=0
    local max_polls=$((timeout_sec / poll_freq))

    log_section "Watchdog — ${label} (PID ${pid})"
    echo "   Timeout: ${TIMEOUT_MS}ms (${timeout_sec}s)"
    echo "   Poll frequency: ${poll_freq}s"
    echo "   Max polls: ${max_polls}"
    echo "   Log file: ${LOG_FILE}"
    echo ""

    # Perform initial deadlock check
    local initial_deadlock
    initial_deadlock="$(check_deadlock "$pid")"
    log_verbose "Initial child process state: ${initial_deadlock}"

    watchdog_log "WATCHDOG_START pid=${pid} label=${label} timeout=${timeout_sec}s poll=${poll_freq}s"

    # Main monitoring loop
    local poll_count=0
    while [[ "$elapsed" -lt "$timeout_sec" ]]; do
        # Check if process has completed
        if ! is_process_running "$pid"; then
            log_pass "Process ${label} (PID ${pid}) completed within timeout."
            watchdog_log "WATCHDOG_COMPLETE pid=${pid} elapsed=${elapsed}s"
            return 0
        fi

        # Deadlock detection
        local deadlock_status
        deadlock_status="$(check_deadlock "$pid")"
        if [[ "$deadlock_status" == "all_sleep" ]]; then
            deadlock_cycles=$((deadlock_cycles + 1))
            log_verbose "Deadlock cycle ${deadlock_cycles}/${DEADLOCK_THRESHOLD}: all children in sleep state"
        else
            deadlock_cycles=0  # reset on any activity
        fi

        if [[ "$deadlock_cycles" -ge "$DEADLOCK_THRESHOLD" ]]; then
            log_fail "Deadlock detected: all children in sleep state for ${deadlock_cycles} cycles."
            watchdog_log "DEADLOCK_DETECTED pid=${pid} cycles=${deadlock_cycles}"
            send_notify "Watchdog" "Deadlock detected in ${label} (PID ${pid})"

            terminate_process "$pid" "$label"
            return 1
        fi

        # Log periodic status
        if [[ "$((poll_count % 6))" -eq 0 ]] || [[ "$VERBOSE" == true ]]; then
            log_verbose "Status: elapsed=${elapsed}s/${timeout_sec}s, polls=${poll_count}, running=true"
        fi

        # Wait for next poll interval
        sleep "$poll_freq"
        elapsed=$((elapsed + poll_freq))
        poll_count=$((poll_count + 1))
    done

    # Timeout reached
    log_fail "Timeout: ${label} (PID ${pid}) exceeded ${timeout_sec}s."
    watchdog_log "TIMEOUT pid=${pid} label=${label} timeout=${timeout_sec}s"

    send_notify "Watchdog Timeout" "${label} (PID ${pid}) exceeded ${timeout_sec}s"

    terminate_process "$pid" "$label"
    return 1
}

# ════════════════════════════════════════════════════════════════════════════
# Validation
# ════════════════════════════════════════════════════════════════════════════

validate_pid() {
    local pid="$1"

    if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
        log_fail "Invalid PID: '${pid}' — must be a numeric value."
        return 1
    fi

    if [[ "$pid" -le 0 ]]; then
        log_fail "Invalid PID: ${pid} — must be a positive integer."
        return 1
    fi

    # Check if process exists (we don't check /proc on macOS, use ps)
    if ! ps -p "$pid" > /dev/null 2>&1; then
        log_fail "Process with PID ${pid} does not exist."
        return 1
    fi

    return 0
}

# ════════════════════════════════════════════════════════════════════════════
# Main
# ════════════════════════════════════════════════════════════════════════════

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                HELP=true
                shift
                ;;
            --watch)
                if [[ -z "${2:-}" ]]; then
                    log_fail "--watch requires a PID argument."
                    exit 2
                fi
                WATCH_PID="$2"
                shift 2
                ;;
            --timeout)
                if [[ -z "${2:-}" ]]; then
                    log_fail "--timeout requires a millisecond value."
                    exit 2
                fi
                TIMEOUT_MS="$2"
                shift 2
                ;;
            --label)
                if [[ -z "${2:-}" ]]; then
                    log_fail "--label requires a name argument."
                    exit 2
                fi
                LABEL="$2"
                shift 2
                ;;
            --notify)
                ENABLE_NOTIFY=true
                shift
                ;;
            --poll)
                if [[ -z "${2:-}" ]]; then
                    log_fail "--poll requires a frequency in seconds."
                    exit 2
                fi
                POLL_FREQ="$2"
                shift 2
                ;;
            --output-dir)
                if [[ -z "${2:-}" ]]; then
                    log_fail "--output-dir requires a directory path."
                    exit 2
                fi
                OUTPUT_DIR="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            *)
                echo -e "${RED}Unknown option:${NC} $1" >&2
                echo "Try '$(basename "$0") --help' for more info." >&2
                exit 2
                ;;
        esac
    done

    # Help first
    if [[ "$HELP" == true ]]; then
        usage
    fi

    # Must have a PID
    if [[ -z "$WATCH_PID" ]]; then
        log_fail "--watch PID is required."
        echo "Try '$(basename "$0") --help' for more info." >&2
        exit 2
    fi

    # Validate PID
    if ! validate_pid "$WATCH_PID"; then
        exit 2
    fi

    # Load config from rules.json (may set TIMEOUT_MS if not already set)
    load_rules_config

    # Validate/derive timeout
    if [[ -z "$TIMEOUT_MS" ]]; then
        TIMEOUT_MS=120000
    fi
    if ! [[ "$TIMEOUT_MS" =~ ^[0-9]+$ ]] || [[ "$TIMEOUT_MS" -le 0 ]]; then
        log_fail "Invalid timeout: ${TIMEOUT_MS}ms — must be a positive integer."
        exit 2
    fi
    TIMEOUT_SEC=$(( (TIMEOUT_MS + 999) / 1000 ))  # round up to nearest second

    # Validate poll frequency
    if ! [[ "$POLL_FREQ" =~ ^[0-9]+$ ]] || [[ "$POLL_FREQ" -le 0 ]]; then
        log_fail "Invalid poll frequency: ${POLL_FREQ}s — must be a positive integer."
        exit 2
    fi

    # Resolve output directory and log file
    if [[ -z "$OUTPUT_DIR" ]]; then
        local session
        session="$(get_session)"
        OUTPUT_DIR="$PROJECT_DIR/session"
    fi
    LOG_FILE="${OUTPUT_DIR}/watchdog.log"
    mkdir -p "$OUTPUT_DIR"

    # Run the watchdog
    local watch_exit=0
    run_watchdog || watch_exit=$?

    exit "$watch_exit"
}

main "$@"
