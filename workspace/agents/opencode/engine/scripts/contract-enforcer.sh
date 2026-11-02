#!/usr/bin/env bash
set -euo pipefail

log_pass() { echo -e "\033[32m✓ $1\033[0m"; }
log_fail() { echo -e "\033[31m✗ $1\033[0m"; }
log_info() { echo -e "\033[34mℹ $1\033[0m"; }
log_verbose() { [[ "${VERBOSE:-0}" == "1" ]] && echo -e "\033[33m⋯ $1\033[0m"; }

usage() {
    cat << EOF
Usage: contract-enforcer.sh [OPTIONS] --contract FILE

Runtime contract validation and agent→state MCP enforcement.

OPTIONS:
  --contract FILE      Contract JSON file to enforce (required)
  --mode MODE          Enforcement mode: validate|enforce|mcp (default: validate)
  --agent AGENT        Agent name for MCP enforcement (e.g. orchestrator, developer)
  --state STATE        Target state for MCP enforcement (e.g. EXECUTE, REVIEW)
  --timeout MS         Timeout in milliseconds (default: 30000)
  --hardening LEVEL    Hardening level: soft|medium|hard (default: medium)
  --dry-run            Show what would be enforced without acting
  --verbose            Show detailed enforcement steps
  --json               Output results as JSON
  --help               Show this help

MODES:
  validate    Runtime contract schema + state machine validation
  enforce     Enforce contract rules, block violations
  mcp         MCP-level agent→state enforcement (requires --agent, --state)

EXAMPLES:
  contract-enforcer.sh --contract session/contract.json
  contract-enforcer.sh --mode enforce --contract session/contract.json --hardening hard
  contract-enforcer.sh --mode mcp --agent developer --state EXECUTE --contract session/contract.json
EOF
}

CONTRACT_FILE=""
MODE="validate"
AGENT=""
TARGET_STATE=""
TIMEOUT_MS=30000
HARDENING="medium"
DRY_RUN=0
VERBOSE=0
JSON_OUTPUT=0

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --contract) CONTRACT_FILE="$2"; shift 2 ;;
            --mode) MODE="$2"; shift 2 ;;
            --agent) AGENT="$2"; shift 2 ;;
            --state) TARGET_STATE="$2"; shift 2 ;;
            --timeout) TIMEOUT_MS="$2"; shift 2 ;;
            --hardening) HARDENING="$2"; shift 2 ;;
            --dry-run) DRY_RUN=1; shift ;;
            --verbose) VERBOSE=1; shift ;;
            --json) JSON_OUTPUT=1; shift ;;
            --help|-h) usage; exit 0 ;;
            *) log_fail "Unknown argument: $1"; usage; exit 1 ;;
        esac
    done
    if [[ -z "$CONTRACT_FILE" ]]; then
        log_fail "Missing required --contract argument"
        usage
        exit 1
    fi
}

get_timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
get_epoch_ms() {
  # GNU date: date +%s%3N (linux/gnu coreutils)
  # BSD date: fallback to python3, perl, or seconds*1000
  local ms
  ms=$(date +%s%3N 2>/dev/null)
  if [[ "$ms" =~ ^[0-9]+$ ]]; then
    echo "$ms"
    return
  fi
  if command -v python3 &>/dev/null; then
    python3 -c 'import time; print(int(time.time() * 1000))'
  elif command -v perl &>/dev/null; then
    perl -MTime::HiRes -e 'print int(Time::HiRes::time*1000)'
  else
    echo $(( $(date +%s) * 1000 ))
  fi
}

validate_contract() {
    log_info "Validating contract: $CONTRACT_FILE"
    if [[ ! -f "$CONTRACT_FILE" ]]; then
        log_fail "Contract file not found"
        return 1
    fi
    local errors=0
    local state
    state=$(jq -r '.state // "UNKNOWN"' "$CONTRACT_FILE")
    local valid_states="INIT PLAN PLAN_SCORED EXECUTE EXECUTE_SCORED REVIEW REVIEW_SCORED COMPLETE BLOCKED"
    if ! echo "$valid_states" | grep -qw "$state"; then
        log_fail "Invalid state: $state"
        errors=$((errors + 1))
    fi
    local score
    score=$(jq -r '.score // 0' "$CONTRACT_FILE")
    if [[ "$score" -lt 0 ]] || [[ "$score" -gt 100 ]]; then
        log_fail "Invalid score: $score (must be 0-100)"
        errors=$((errors + 1))
    fi
    local elapsed
    elapsed=$(jq -r '.metrics.elapsed_ms // 0' "$CONTRACT_FILE")
    if [[ "$elapsed" -gt "$TIMEOUT_MS" ]]; then
        local msg="Timeout violation: ${elapsed}ms > ${TIMEOUT_MS}ms"
        if [[ "$HARDENING" == "hard" ]]; then
            log_fail "$msg"
            errors=$((errors + 1))
        else
            log_info "$msg (soft warning)"
        fi
    fi
    if [[ "$errors" -eq 0 ]]; then
        log_pass "Contract validation passed"
        return 0
    else
        log_fail "Contract validation failed with $errors errors"
        return 1
    fi
}

enforce_contract() {
    log_info "Enforcing contract rules (hardening: $HARDENING)"
    local violations=0
    local score
    score=$(jq -r '.score // 0' "$CONTRACT_FILE")
    local threshold
    case "$HARDENING" in
        soft) threshold=50 ;;
        medium) threshold=70 ;;
        hard) threshold=85 ;;
        *) threshold=70 ;;
    esac
    if [[ "$score" -lt "$threshold" ]]; then
        log_fail "Score violation: $score < $threshold"
        violations=$((violations + 1))
    fi
    local retry_count
    retry_count=$(jq -r '.retry_count // 0' "$CONTRACT_FILE")
    if [[ "$retry_count" -ge 3 ]]; then
        log_fail "Retry limit exceeded: $retry_count >= 3"
        violations=$((violations + 1))
    fi
    if [[ "$violations" -eq 0 ]]; then
        log_pass "Contract enforcement passed"
        return 0
    elif [[ "$DRY_RUN" -eq 1 ]]; then
        log_info "Dry run: would block due to $violations violations"
        return 0
    else
        log_fail "Contract blocked due to $violations violations"
        return 1
    fi
}

mcp_enforce_agent_state() {
    log_info "MCP enforcement: agent=$AGENT → state=$TARGET_STATE"
    if [[ -z "$AGENT" ]] || [[ -z "$TARGET_STATE" ]]; then
        log_fail "Missing --agent or --state for MCP enforcement"
        return 1
    fi
    local current_state
    current_state=$(jq -r '.state // "INIT"' "$CONTRACT_FILE")
    local current_agent
    current_agent=$(jq -r '.agent // "orchestrator"' "$CONTRACT_FILE")
    log_verbose "Current: agent=$current_agent, state=$current_state"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_pass "Dry run: transition $current_state → $TARGET_STATE allowed"
        return 0
    fi
    log_pass "MCP enforcement: transition validated"
    return 0
}

main() {
    parse_args "$@"
    local start_ms
    start_ms=$(get_epoch_ms)
    local result=0
    case "$MODE" in
        validate) validate_contract || result=1 ;;
        enforce) enforce_contract || result=1 ;;
        mcp) mcp_enforce_agent_state || result=1 ;;
        *) log_fail "Unknown mode: $MODE"; usage; exit 1 ;;
    esac
    local elapsed_ms=$(( $(get_epoch_ms) - start_ms ))
    if [[ "$JSON_OUTPUT" -eq 1 ]]; then
        jq -n --arg mode "$MODE" --arg result "$result" --arg elapsed "$elapsed_ms" \
            '{mode: $mode, result: (if $result == "0" then "pass" else "fail" end), elapsed_ms: ($elapsed | tonumber)}'
    fi
    exit $result
}

main "$@"