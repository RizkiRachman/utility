#!/usr/bin/env bash
# =============================================================================
# verify-knowledge.sh — Verify lean-ctx knowledge persistence after a phase
#
# Checks if decisions, gotchas, patterns, and lessons_learned were actually
# persisted to lean-ctx after a phase completes. Queries the knowledge base
# and reports coverage.
#
# Usage:
#   ./scripts/verify-knowledge.sh --phase PLAN      # Verify PLAN phase
#   ./scripts/verify-knowledge.sh --phase EXECUTE   # Verify EXECUTE phase
#   ./scripts/verify-knowledge.sh --all             # Check all phases
#   ./scripts/verify-knowledge.sh --contract path   # Use specific contract
#   ./scripts/verify-knowledge.sh --dry-run         # Preview checks
#   ./scripts/verify-knowledge.sh --help            # Show this message
#
# Exit codes:
#   0 = PASS (coverage ≥ 70% or nothing expected)
#   1 = FAIL (coverage < 70%)
#   2 = ERROR
# =============================================================================

set -euo pipefail

# --- Config ----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/paths.sh"  # N1: session state lives with the project
PROJECT_DIR="$(resolve_project_root "${SCRIPT_DIR}/..")"

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
PHASE=""
CHECK_ALL=false
CONTRACT_FILE=""
DRY_RUN=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# --- Help ------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Verify that knowledge was persisted to lean-ctx after a phase completes.

Options:
  --phase PHASE       Phase to verify (PLAN|EXECUTE|REVIEW|COMPLETE)
  --all               Verify knowledge for all phases
  --contract PATH     Contract JSON file (default: auto-detect from session)
  --dry-run           Show what would be checked without running queries
  --help              Show this message

Exit codes:
  0   Coverage ≥ 70% or nothing expected
  1   Coverage < 70%
  2   Error (missing deps, invalid args)

Examples:
  $(basename "$0") --phase PLAN
  $(basename "$0") --all
  $(basename "$0") --phase EXECUTE --contract session/foo/contract.json
EOF
    exit 0
}

# --- Logging functions -----------------------------------------------------
# log_pass/log_fail/log_info come from scripts/lib.

# --- Phase definitions -----------------------------------------------------
# Each phase has a list of categories and their expected minimum entries.
declare -A PHASE_CATEGORIES
PHASE_CATEGORIES[PLAN]="architecture patterns"
PHASE_CATEGORIES[EXECUTE]="architecture patterns conventions"
PHASE_CATEGORIES[REVIEW]="testing quality architecture"
PHASE_CATEGORIES[COMPLETE]="lessons gotchas"

declare -A EXPECTED_ENTRIES
# PLAN
EXPECTED_ENTRIES[PLAN:architecture]=3
EXPECTED_ENTRIES[PLAN:patterns]=2
# EXECUTE
EXPECTED_ENTRIES[EXECUTE:architecture]=1
EXPECTED_ENTRIES[EXECUTE:patterns]=3
EXPECTED_ENTRIES[EXECUTE:conventions]=2
# REVIEW
EXPECTED_ENTRIES[REVIEW:testing]=2
EXPECTED_ENTRIES[REVIEW:quality]=2
EXPECTED_ENTRIES[REVIEW:architecture]=1
# COMPLETE
EXPECTED_ENTRIES[COMPLETE:lessons]=3
EXPECTED_ENTRIES[COMPLETE:gotchas]=1

# --- Parse arguments -------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --phase)
            shift
            PHASE="$1"
            case "$PHASE" in
                PLAN|EXECUTE|REVIEW|COMPLETE) ;;
                *) echo "Error: Invalid phase '$PHASE'. Valid: PLAN, EXECUTE, REVIEW, COMPLETE" >&2
                   exit 2 ;;
            esac
            ;;
        --all) CHECK_ALL=true ;;
        --contract)
            shift
            CONTRACT_FILE="$1"
            ;;
        --dry-run) DRY_RUN=true ;;
        --help) usage ;;
        *) echo "Error: Unknown option '$1'. Use --help for usage." >&2
           exit 2 ;;
    esac
    shift
done

# --- Pre-flight checks -----------------------------------------------------

# jq must be available
if ! command -v jq &>/dev/null; then
    echo "Error: jq is required but not installed." >&2
    exit 2
fi

# lean-ctx availability check
LEAN_CTX_AVAILABLE=false
if command -v lean-ctx &>/dev/null; then
    LEAN_CTX_AVAILABLE=true
else
    log_info "lean-ctx not available, cannot verify knowledge. Try: lean-ctx ctx_knowledge status"
fi

# Determine which phases to check
PHASES_TO_CHECK=()
if [[ -n "$PHASE" ]]; then
    PHASES_TO_CHECK+=("$PHASE")
elif [[ "$CHECK_ALL" == true ]]; then
    PHASES_TO_CHECK=(PLAN EXECUTE REVIEW COMPLETE)
else
    echo "Error: Specify --phase PHASE or --all" >&2
    exit 2
fi

# Auto-detect contract file if not specified
if [[ -z "$CONTRACT_FILE" ]]; then
    local_br="$(echo session 2>/dev/null || echo "")"
    if [[ -n "$local_br" && "$local_br" != "HEAD" ]]; then
        CONTRACT_FILE="$PROJECT_DIR/session/contract.json"
        if [[ ! -f "$CONTRACT_FILE" ]]; then
            CONTRACT_FILE="$PROJECT_DIR/contract/contract.template.json"
        fi
    else
        CONTRACT_FILE="$PROJECT_DIR/contract/contract.template.json"
    fi
fi

# --- Core verification ----------------------------------------------------

# Run a lean-ctx query and return the number of results (or 0 on failure)
count_knowledge_entries() {
    local category="$1"
    if [[ "$LEAN_CTX_AVAILABLE" != true ]]; then
        echo 0
        return
    fi
    local result
    result=$(lean-ctx ctx_knowledge recall --query "$category" --mode semantic 2>/dev/null) || true
    # Count non-empty lines as entries (heuristic)
    echo "$result" | grep -cE '.+' 2>/dev/null || echo 0
}

# Get lessons_learned count from contract JSON
count_lessons_in_contract() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        echo 0
        return
    fi
    jq -r '.lessons_learned | length' "$file" 2>/dev/null || echo 0
}

verify_phase() {
    local phase="$1"
    local contract_file="$2"
    local categories_str="${PHASE_CATEGORIES[$phase]}"
    IFS=' ' read -ra categories <<< "$categories_str"

    local total_expected=0
    local total_found=0
    local output_lines=()
    local has_lessons_check=false

    for cat in "${categories[@]}"; do
        local key="${phase}:${cat}"
        local expected="${EXPECTED_ENTRIES[$key]:-0}"
        total_expected=$((total_expected + expected))

        local found=0
        if [[ "$DRY_RUN" == true ]]; then
            found="?"
        else
            found=$(count_knowledge_entries "$cat")
        fi

        local status
        if [[ "$DRY_RUN" == true ]]; then
            status="${YELLOW}?${NC}"
            output_lines+=("  ${cat}: ${status} would check (expected ≥ ${expected})")
        elif [[ "$found" -ge "$expected" ]]; then
            status="${GREEN}✓${NC}"
            total_found=$((total_found + expected))
            output_lines+=("  $(log_pass "${cat}: ${found} entries found (expected ≥ ${expected})")")
        elif [[ "$found" -eq 0 && "$expected" -eq 0 ]]; then
            status="${GREEN}✓${NC}"
            total_found=$((total_found + 0))
            output_lines+=("  $(log_pass "${cat}: 0 entries (nothing expected)")")
        else
            status="${RED}✗${NC}"
            output_lines+=("  $(log_fail "${cat}: ${found} entries (expected ≥ ${expected})")")
        fi
    done

    # Check lessons_learned from contract (special case)
    if [[ "$phase" == "COMPLETE" ]]; then
        local lessons_count
        if [[ "$DRY_RUN" == true ]]; then
            lessons_count="?"
        else
            lessons_count=$(count_lessons_in_contract "$contract_file")
        fi
        has_lessons_check=true

        if [[ "$DRY_RUN" == true ]]; then
            output_lines+=("  Lessons learned: ${YELLOW}?${NC} would check contract.lessons_learned")
        elif [[ "$lessons_count" -gt 0 ]]; then
            total_expected=$((total_expected + 1))
            total_found=$((total_found + 1))
            output_lines+=("  $(log_pass "Lessons learned: ${lessons_count} entries (from contract.lessons_learned)")")
        else
            # No lessons in contract — nothing expected, not a failure
            output_lines+=("  $(log_info "Lessons learned: 0 entries (nothing expected)")")
        fi
    fi

    # Summary
    local coverage=0
    local status_line=""
    if [[ "$DRY_RUN" == true ]]; then
        status_line="  ----------------------------------------\n  Coverage: would compute from results\n  Status: dry run"
    elif [[ "$total_expected" -eq 0 ]]; then
        status_line="  ----------------------------------------\n  Coverage: N/A (nothing expected)\n  ${GREEN}Status: PASS${NC}"
    else
        coverage=$(( total_found * 100 / total_expected ))
        if [[ "$coverage" -ge 70 ]]; then
            status_line="  ----------------------------------------\n  Coverage: ${coverage}% (${total_found}/${total_expected} expected entries found)\n  ${GREEN}Status: PASS${NC} (≥ 70%)"
        else
            status_line="  ----------------------------------------\n  Coverage: ${coverage}% (${total_found}/${total_expected} expected entries found)\n  ${RED}Status: FAIL${NC} (< 70%)"
        fi
    fi

    echo ""
    echo -e "Knowledge Persistence Report (${BOLD}${phase} phase${NC}):"
    for line in "${output_lines[@]}"; do
        echo -e "$line"
    done
    echo -e "$status_line"

    # Return 0 for pass, 1 for fail
    if [[ "$DRY_RUN" == true ]]; then
        return 0
    fi
    if [[ "$total_expected" -eq 0 ]]; then
        return 0
    fi
    if [[ "$coverage" -ge 70 ]]; then
        return 0
    fi
    return 1
}

# --- Main ------------------------------------------------------------------

OVERALL_EXIT=0

for phase in "${PHASES_TO_CHECK[@]}"; do
    if ! verify_phase "$phase" "$CONTRACT_FILE"; then
        OVERALL_EXIT=1
    fi
done

exit "$OVERALL_EXIT"