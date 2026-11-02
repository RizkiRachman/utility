#!/usr/bin/env bash
set -euo pipefail
# uncertainty-router.sh -- Uncertainty-Based Routing (G27)
# Routes decisions based on confidence/uncertainty level. When the orchestrator
# has low confidence in a decision, routes to appropriate escalation paths.
# Routing (thresholds from rules.json -> decisions.confidence_journal):
#   0-30   -> ESCALATE to user    (exit 2)
#   31-60  -> COUNCIL/REVIEW      (exit 1)
#   61-85  -> PROCEED WITH NOTES  (exit 0)
#   86-100 -> AUTO-APPROVE        (exit 0)
# Usage:
#   --score N          Confidence score (0-100). Required.
#   --domain TEXT      Decision domain (code, architecture, security, etc.)
#   --advisory-only    Print recommendation, don't block (exit 0 always)
#   --verbose, --dry-run, --help
# Exit: 0=proceed, 1=review, 2=blocked, 3=error, 4=usage

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
SCORE=""; DOMAIN=""; ADVISORY_ONLY=false; VERBOSE=false; DRY_RUN=false

usage() {
  cat <<'USAGE_EOF'
uncertainty-router.sh - Uncertainty-Based Routing (G27)

Route decisions based on confidence level. Routes to escalation paths.

Usage:
  --score N          Confidence score (0-100). Required.
  --domain TEXT      Decision domain: code, architecture, security, testing,
                     deployment, requirements, process, governance.
  --advisory-only    Print recommendation without blocking (exit 0)
  --verbose          Show routing details
  --dry-run          Simulate without action
  --help             This message

Routing table (thresholds from rules.json -> decisions.confidence_journal):
  Score Range    | Action         | Exit
  0-30           | ESCALATE       | 2 (blocked, needs human)
  31-60          | COUNCIL/REVIEW | 1 (needs multi-agent review)
  61-85          | PROCEED+NOTES  | 0 (continue with notes)
  86-100         | AUTO-APPROVE   | 0 (approve)

  --advisory-only overrides exit codes: always returns 0.

Exit codes: 0=proceed, 1=review, 2=blocked, 3=error, 4=usage
USAGE_EOF
}

# log_pass/log_fail/log_info/log_verbose/log_dry come from scripts/lib.
log_section() { echo -e "${BOLD}  $1${NC}"; echo "  $(printf '%*s' "$((${#1}+2))" '' | tr ' ' '-')"; }

validate_score() {
  local s="$1"
  if [[ -z "$s" ]]; then log_fail "--score N required (0-100)"; return 3; fi
  if ! [[ "$s" =~ ^[0-9]+$ ]]; then log_fail "Score must be integer (got: '$s')"; return 3; fi
  if [[ "$s" -lt 0 || "$s" -gt 100 ]]; then log_fail "Score must be 0-100 (got: $s)"; return 3; fi
  return 0
}

validate_domain() {
  local d="$1"
  if [[ -z "$d" ]]; then log_fail "--domain required"; return 3; fi
  local known=(code architecture security testing deployment requirements process governance)
  for k in "${known[@]}"; do [[ "$k" == "$d" ]] && return 0; done
  log_verbose "Domain '$d' not in standard list, continuing as custom"
  return 0
}

load_rules_config() {
  local f="$PROJECT_DIR/rules/rules.json"
  if [[ ! -f "$f" ]]; then echo "35 65 85 100"; return; fi
  if ! command -v jq &>/dev/null; then echo "35 65 85 100"; return; fi
  # Map 1-5 scale from rules.json to 0-100: threshold = (raw * 20) - 10
  local er; er=$(jq -r '.decisions.confidence_journal.escalate_below // 2' "$f" 2>/dev/null || echo 2)
  local mr; mr=$(jq -r '.decisions.confidence_journal.min_confidence_to_proceed // 3' "$f" 2>/dev/null || echo 3)
  local em=$(( er * 20 - 10 )); [[ $em -lt 0 ]] && em=0; [[ $em -gt 100 ]] && em=100
  local pm=$(( mr * 20 - 10 )); [[ $pm -lt 0 ]] && pm=0; [[ $pm -gt 100 ]] && pm=100
  local cm=$(( (em + pm) / 2 ))
  local am=$(( pm + 20 )); [[ $am -gt 100 ]] && am=100
  echo "$em $cm $pm $am"
}

route_decision() {
  local s="$1"
  read -r et ct pt at <<< "$(load_rules_config)"
  if [[ "$s" -lt "$et" ]]; then echo "ESCALATE|Escalate to user|High uncertainty (${s}/${at}) - needs human judgment|2"
  elif [[ "$s" -lt "$ct" ]]; then echo "COUNCIL|Council/Review|Moderate uncertainty (${s}/${at}) - multi-agent consensus recommended|1"
  elif [[ "$s" -lt "$at" ]]; then echo "PROCEED|Proceed with Notes|Acceptable confidence (${s}/${at}) - proceed, flag concerns for review|0"
  else echo "AUTO|Auto-Approve|High confidence (${s}/${at}) - proceed without review|0"; fi
}

print_recommendation() {
  local level="$1" label="$2" desc="$3" exit_code="$4" domain="$5" score="$6"
  local lc=""; case "$level" in
    ESCALATE) lc="${RED}${level}${NC}" ;;
    COUNCIL)  lc="${YELLOW}${level}${NC}" ;;
    PROCEED)  lc="${CYAN}${level}${NC}" ;;
    AUTO)     lc="${GREEN}${level}${NC}" ;;
    *)        lc="${level}" ;;
  esac
  # Display thresholds from rules.json
  if [[ "$VERBOSE" == true ]]; then
    read -r et ct pt at <<< "$(load_rules_config)"
    log_verbose "Thresholds: esc<$et council<$ct proc<$pt auto>=$at"
  fi
  log_section "Uncertainty Routing - ${domain}"
  echo "  Domain:   ${CYAN}${domain}${NC}"
  echo "  Score:    ${score}/100"
  echo "  Routing:  ${lc}"
  echo "  Action:   ${label}"
  echo "  Rationale: ${desc}"
  if [[ "$ADVISORY_ONLY" == true && "$exit_code" -gt 0 ]]; then
    echo "  Advisory: ${YELLOW}non-blocking${NC}"; fi
  case "$domain" in
    architecture) echo "  Guidance: Consider ADR entry, document trade-offs" ;;
    security)     echo "  Guidance: Run threat model; involve security-expert" ;;
    deployment)   echo "  Guidance: Check rollback plan, smoke tests, canary" ;;
    testing)      echo "  Guidance: Verify test coverage meets thresholds" ;;
    requirements) echo "  Guidance: Document ambiguity, re-confirm with stakeholder" ;;
    code)         echo "  Guidance: Run ctx_impact, check blast radius" ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 4 ;;
    --score) SCORE="$2"; shift 2 ;;
    --domain) DOMAIN="$2"; shift 2 ;;
    --advisory-only) ADVISORY_ONLY=true; shift ;;
    --verbose) VERBOSE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) echo "Unknown: $1. Use --help." >&2; exit 4 ;;
  esac
done

[[ -z "$SCORE" || -z "$DOMAIN" ]] && { echo -e "${RED}Error:${NC} --score and --domain required. Use --help." >&2; exit 3; }
validate_score "$SCORE" || exit 3
validate_domain "$DOMAIN" || exit 3

IFS='|' read -r level label desc exit_code <<< "$(route_decision "$SCORE")"
print_recommendation "$level" "$label" "$desc" "$exit_code" "$DOMAIN" "$SCORE"

[[ "$ADVISORY_ONLY" == true && "$exit_code" -gt 0 ]] && { log_info "Advisory-only: returning 0"; exit 0; }
[[ "$DRY_RUN" == true ]] && { log_dry "Dry-run complete - would exit $exit_code"; exit 0; }
exit "$exit_code"
