#!/usr/bin/env bash
set -euo pipefail

log_pass() { echo -e "\033[32m✓ $1\033[0m"; }
log_fail() { echo -e "\033[31m✗ $1\033[0m"; }
log_info() { echo -e "\033[34mℹ $1\033[0m"; }
log_verbose() { [[ "${VERBOSE:-0}" == "1" ]] && echo -e "\033[33m⋯ $1\033[0m"; }

usage() {
    cat << EOF
Usage: scheduled-runner.sh [OPTIONS] --task TASK

Scheduled/recurring task runner for autonomous operations.

OPTIONS:
  --task TASK           Task to run periodically (required)
  --schedule CRON       Cron schedule expression (default: hourly)
  --max-runs N          Maximum runs before stopping (default: unlimited)
  --directory DIR       Working directory (default: .)
  --contract FILE       Contract file to monitor
  --notify-mode MODE    Notification mode: none|slack|email|log (default: log)
  --fail-mode MODE      Failure handling: continue|stop|retry (default: continue)
  --health-check CMD    Health check command to run before each execution
  --pid-file FILE       PID file for daemon management (default: scheduled-runner.pid)
  --stop                Stop the running scheduler
  --status              Show scheduler status
  --run-once            Run task once and exit (no scheduling)
  --dry-run             Show what would run without executing
  --verbose             Show detailed scheduling output
  --json                Output results as JSON
  --help                Show this help

SCHEDULE FORMATS:
  hourly        Run every hour
  daily         Run every day at midnight
  every-N       Run every N minutes (e.g., every-30)
  cron          Standard cron expression (e.g., "0 * * * *")

TASK OPTIONS:
  validate      Run contract validation
  drift-detect  Run drift detection
  health        Run MCP health check
  metrics       Aggregate metrics

EXAMPLES:
  scheduled-runner.sh --task validate --schedule hourly
  scheduled-runner.sh --task drift-detect --schedule every-30
  scheduled-runner.sh --task health --run-once
  scheduled-runner.sh --stop
EOF
}

TASK=""
SCHEDULE="hourly"
MAX_RUNS=0
DIRECTORY="."
CONTRACT_FILE=""
NOTIFY_MODE="log"
FAIL_MODE="continue"
HEALTH_CHECK=""
PID_FILE="scheduled-runner.pid"
DRY_RUN=0
VERBOSE=0
JSON_OUTPUT=0
RUN_ONCE=0
ACTION="start"

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --task) TASK="$2"; shift 2 ;;
            --schedule) SCHEDULE="$2"; shift 2 ;;
            --max-runs) MAX_RUNS="$2"; shift 2 ;;
            --directory) DIRECTORY="$2"; shift 2 ;;
            --contract) CONTRACT_FILE="$2"; shift 2 ;;
            --notify-mode) NOTIFY_MODE="$2"; shift 2 ;;
            --fail-mode) FAIL_MODE="$2"; shift 2 ;;
            --health-check) HEALTH_CHECK="$2"; shift 2 ;;
            --pid-file) PID_FILE="$2"; shift 2 ;;
            --stop) ACTION="stop"; shift ;;
            --status) ACTION="status"; shift ;;
            --run-once) RUN_ONCE=1; shift ;;
            --dry-run) DRY_RUN=1; shift ;;
            --verbose) VERBOSE=1; shift ;;
            --json) JSON_OUTPUT=1; shift ;;
            --help|-h) usage; exit 0 ;;
            *) log_fail "Unknown argument: $1"; usage; exit 1 ;;
        esac
    done
}

get_timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
get_epoch_ms() { date +%s%3N; }

parse_schedule() {
    local interval_seconds=3600
    case "$SCHEDULE" in
        hourly) interval_seconds=3600 ;;
        daily) interval_seconds=86400 ;;
        every-*)
            local mins=$(echo "$SCHEDULE" | sed 's/every-//')
            interval_seconds=$((mins * 60))
            ;;
        cron)
            log_info "Cron schedule: $SCHEDULE (parsed by external cron)"
            interval_seconds=0
            ;;
    esac
    return $interval_seconds
}

run_task() {
    log_info "Running task: $TASK"
    local exit_code=0
    case "$TASK" in
        validate)
            if [[ -f "$CONTRACT_FILE" ]]; then
                bash scripts/validate-contract.sh --file "$CONTRACT_FILE" || exit_code=1
            else
                log_fail "No contract file specified"
                exit_code=1
            fi
            ;;
        drift-detect)
            bash scripts/drift-detect.sh 2>/dev/null || exit_code=1
            ;;
        health)
            bash scripts/mcp-health.sh --mode quick || exit_code=1
            ;;
        metrics)
            bash scripts/metrics-aggregator.sh --mode summary || exit_code=1
            ;;
        *)
            log_fail "Unknown task: $TASK"
            exit_code=1
            ;;
    esac
    return $exit_code
}

run_scheduler() {
    parse_schedule
    local interval=$?
    local run_count=0
    log_info "Starting scheduler (task: $TASK, interval: ${interval}s)"
    while true; do
        if [[ -n "$HEALTH_CHECK" ]]; then
            eval "$HEALTH_CHECK" || {
                log_fail "Health check failed, skipping run"
                continue
            }
        fi
        if [[ "$DRY_RUN" -eq 1 ]]; then
            log_info "Dry run: would execute $TASK"
            break
        fi
        run_task
        local result=$?
        run_count=$((run_count + 1))
        if [[ "$result" -ne 0 ]]; then
            case "$FAIL_MODE" in
                continue) log_info "Task failed, continuing (run $run_count)" ;;
                stop) log_fail "Task failed, stopping scheduler"; break ;;
                retry) log_info "Task failed, will retry next cycle" ;;
            esac
        else
            log_pass "Task completed (run $run_count)"
        fi
        case "$NOTIFY_MODE" in
            slack) log_info "Slack notification: task $TASK completed" ;;
            email) log_info "Email notification: task $TASK completed" ;;
            log) echo "$(get_timestamp) RUN $run_count $TASK result=$result" >> scheduled-runner.log ;;
        esac
        if [[ "$MAX_RUNS" -gt 0 ]] && [[ "$run_count" -ge "$MAX_RUNS" ]]; then
            log_info "Max runs reached ($MAX_RUNS), stopping"
            break
        fi
        if [[ "$RUN_ONCE" -eq 1 ]]; then
            break
        fi
        if [[ "$interval" -gt 0 ]]; then
            log_verbose "Sleeping $interval seconds..."
            sleep "$interval" || break
        fi
    done
}

main() {
    parse_args "$@"
    case "$ACTION" in
        start)
            if [[ "$RUN_ONCE" -eq 1 ]] || [[ "$DRY_RUN" -eq 1 ]]; then
                run_scheduler
            else
                run_scheduler &
                echo $! > "$PID_FILE"
                log_pass "Scheduler started (PID: $(cat $PID_FILE))"
            fi
            ;;
        stop)
            if [[ -f "$PID_FILE" ]]; then
                kill "$(cat $PID_FILE)" 2>/dev/null || true
                rm -f "$PID_FILE"
                log_pass "Scheduler stopped"
            fi
            ;;
        status)
            if [[ -f "$PID_FILE" ]]; then
                log_pass "Scheduler running (PID: $(cat $PID_FILE))"
            else
                log_info "Scheduler not running"
            fi
            ;;
        *) log_fail "Unknown action: $ACTION"; exit 1 ;;
    esac
}

main "$@"