#!/usr/bin/env bash
# check-architecture-drift.sh — Detect drift between contract architecture spec and actual code
# Usage: bash scripts/check-architecture-drift.sh [--file CONTRACT_JSON]
# Example: bash scripts/check-architecture-drift.sh --file session/contract.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/paths.sh"  # N1: session state lives with the project
PROJECT_DIR="$(resolve_project_root "${SCRIPT_DIR}/..")"
CONTRACT_FILE=""
DRY_RUN=false

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
# log_detail stays local (uses BLUE, absent from the lib palette).
log_detail() { echo -e "  ${BLUE}→${NC} $1"; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Detect architecture drift between contract specification and actual code.

Options:
  --file PATH         Contract JSON file (default: auto-detect from session)
  --dry-run           Show what would be checked without running
  --help              Show this message
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --file) CONTRACT_FILE="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help|-h) usage ;;
        *) echo "Unknown: $1"; usage ;;
    esac
done

# Auto-detect contract
if [[ -z "$CONTRACT_FILE" ]]; then
    SESSION_ID=$(echo session 2>/dev/null || echo "unknown")
    CANDIDATES=(
        "$PROJECT_DIR/session/contract.json"
        "$PROJECT_DIR/contract/contract.json"
        "$PROJECT_DIR/contract/contract.template.json"
    )
    for f in "${CANDIDATES[@]}"; do
        if [[ -f "$f" ]]; then CONTRACT_FILE="$f"; break; fi
    done
fi

if [[ -z "$CONTRACT_FILE" || ! -f "$CONTRACT_FILE" ]]; then
    log_fail "No contract file found. Use --file PATH"
    exit 2
fi

DRIFT_COUNT=0
CRITICAL_DRIFT=false

echo "=========================================="
echo " Architecture Drift Detection"
echo " Contract: $CONTRACT_FILE"
echo "=========================================="
echo ""

# Read contract fields
STATE=$(jq -r '.state // "INIT"' "$CONTRACT_FILE")
ARCH=$(jq -r '.outputs.architecture // ""' "$CONTRACT_FILE" | head -c 500)
SCOPE_INCLUDED=$(jq -r '.scope.included[] // empty' "$CONTRACT_FILE" 2>/dev/null || true)
CODE_CHANGES=$(jq -r '.outputs.code_changes // [] | length' "$CONTRACT_FILE")

state_rank=$(echo "$STATE" | awk '{for(i=0;i<10;i++){if($1=="INIT"){print 0;next} if($1=="PLAN"){print 1;next} if($1=="PLAN_SCORED"){print 2;next} if($1=="EXECUTE"){print 4;next} if($1=="EXECUTE_SCORED"){print 5;next} if($1=="REVIEW"){print 6;next} if($1=="REVIEW_SCORED"){print 7;next} if($1=="COMPLETE"){print 8;next} if($1=="BLOCKED"){print 9;next} next}{print 0}}')
if [[ "$state_rank" -lt 5 ]]; then
    log_info "State '$STATE' - architecture drift check deferred until EXECUTE_SCORED+"
    exit 0
fi

if $DRY_RUN; then
    log_info "DRY RUN - no checks actually executed"
    exit 0
fi

# Check 1: Architecture spec exists for post-EXECUTE states
log_info "Checking architecture spec completeness..."
if [[ -z "$ARCH" || "$ARCH" == "null" ]]; then
    log_fail "outputs.architecture is empty - architecture spec missing"
    DRIFT_COUNT=$((DRIFT_COUNT + 1))
    CRITICAL_DRIFT=true
else
    log_pass "Architecture spec present (${#ARCH} chars)"
fi

# Check 2: Code changes exist for EXECUTE_SCORED+
log_info "Checking code changes alignment..."
if [[ "$CODE_CHANGES" -eq 0 && "$state_rank" -ge 5 ]]; then
    log_fail "outputs.code_changes is empty but state is $STATE"
    DRIFT_COUNT=$((DRIFT_COUNT + 1))
else
    log_pass "Code changes tracked: $CODE_CHANGES entries"
fi

# Check 3: Detect layer violations in scope files
log_info "Checking layer boundary violations..."
if [[ -n "$SCOPE_INCLUDED" ]]; then
    LAYER_VIOLATIONS=0
    while IFS= read -r f; do
        if [[ -z "$f" ]]; then continue; fi
        # Detect adapter referenced from service layer
        if echo "$f" | grep -qE '(service|services)/' && echo "$f" | grep -qE 'adapter|repository|external'; then
            log_fail "Layer violation: $f - service layer should not contain adapter"
            DRIFT_COUNT=$((DRIFT_COUNT + 1))
            LAYER_VIOLATIONS=$((LAYER_VIOLATIONS + 1))
        fi
        # Detect port referenced from adapter
        if echo "$f" | grep -qE '(adapter|adapters)/' && echo "$f" | grep -qE 'port|spi|inbound'; then
            log_fail "Layer violation: $f - adapter should not define ports"
            DRIFT_COUNT=$((DRIFT_COUNT + 1))
            LAYER_VIOLATIONS=$((LAYER_VIOLATIONS + 1))
        fi
    done <<< "$SCOPE_INCLUDED"
    if [[ "$LAYER_VIOLATIONS" -eq 0 ]]; then
        log_pass "No layer boundary violations"
    fi
else
    log_info "No scope files to check"
fi

# Check 4: Architecture mentions in spec should match scope file patterns
log_info "Checking architecture-to-scope alignment..."
if [[ -n "$ARCH" && "$ARCH" != "null" ]]; then
    ARCH_LOWER=$(echo "$ARCH" | tr '[:upper:]' '[:lower:]')
    # If spec mentions hexagonal/ports-and-adapters, expect port/ and adapter/ dirs
    if echo "$ARCH_LOWER" | grep -qE 'hexagonal|port.*adapter|onion|clean.?arch'; then
        HAS_PORT=false; HAS_ADAPTER=false
        while IFS= read -r f; do
            if [[ -z "$f" ]]; then continue; fi
            if echo "$f" | grep -qE '(^|/)port(s)?/'; then HAS_PORT=true; fi
            if echo "$f" | grep -qE '(^|/)adapter(s)?/'; then HAS_ADAPTER=true; fi
        done <<< "$SCOPE_INCLUDED"
        if ! $HAS_PORT && ! $HAS_ADAPTER; then
            log_fail "Architecture specifies ports-and-adapters but no port/ or adapter/ dirs in scope"
            DRIFT_COUNT=$((DRIFT_COUNT + 1))
        else
            log_pass "Architecture pattern matches scope directory structure"
        fi
    fi
    # Check for cross-service contract violations
    if echo "$ARCH_LOWER" | grep -qE 'service|microservice|bounded.?context'; then
        if echo "$ARCH_LOWER" | grep -q 'contract'; then
            META_CONTRACT="$PROJECT_DIR/contract/meta-contract.template.json"
            if [[ -f "$META_CONTRACT" ]]; then
                log_pass "Meta-contract exists for cross-service validation"
            else
                log_info "Architecture references cross-service contracts but meta-contract not used"
            fi
        fi
    fi
fi

# Check 5: Scope files actually exist on disk
log_info "Checking scope files exist on disk..."
MISSING_FILES=0
while IFS= read -r f; do
    if [[ -z "$f" ]]; then continue; fi
    full_path="$PROJECT_DIR/$f"
    if [[ ! -f "$full_path" ]]; then
        log_fail "Scope file does not exist: $f"
        DRIFT_COUNT=$((DRIFT_COUNT + 1))
        MISSING_FILES=$((MISSING_FILES + 1))
    fi
done <<< "$SCOPE_INCLUDED"
if [[ "$MISSING_FILES" -eq 0 ]]; then
    log_pass "All scope files exist on disk"
fi

# Summary
echo ""
echo "------------------------------------------"
echo " Drift items detected: $DRIFT_COUNT"
echo "------------------------------------------"

if [[ "$DRIFT_COUNT" -eq 0 ]]; then
    echo -e "${GREEN}VERDICT: NO DRIFT${NC}"
    exit 0
elif $CRITICAL_DRIFT; then
    echo -e "${RED}VERDICT: CRITICAL DRIFT - implementation diverges from architecture${NC}"
    exit 2
else
    echo -e "${YELLOW}VERDICT: MINOR DRIFT - review recommendations above${NC}"
    exit 1
fi
