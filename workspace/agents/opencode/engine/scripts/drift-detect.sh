#!/usr/bin/env bash
# =============================================================================
# drift-detect.sh — Contract Drift Check
#
# Compares lean-ctx knowledge version of the contract against
# session/contract.json file. Reports mismatches in state,
# score, outputs.
#
# Usage:
#   scripts/drift-detect.sh                             # Auto-detect session
#   scripts/drift-detect.sh --session my-session        # Override session id
#   scripts/drift-detect.sh --file session/contract.json  # Specific file
#   scripts/drift-detect.sh --no-knowledge              # Skip knowledge read
#   scripts/drift-detect.sh --verbose                   # Show full diff
#   scripts/drift-detect.sh --help
#
# Exit codes:
#   0 = no drift
#   1 = drift detected
#   2 = error
# =============================================================================

set -euo pipefail

# --- Config ----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SESSION_ID=""
CONTRACT_FILE=""
NO_KNOWLEDGE=false
VERBOSE=false
HELP=false
DRIFT_COUNT=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- Help ------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Compare lean-ctx knowledge version of the orchestration contract against
session/contract.json. Reports mismatches in state, score, and outputs.

Options:
  --session NAME      Override session id (default: session)
  --file PATH        Specific contract JSON file to compare against
  --no-knowledge     Skip knowledge read (file-only syntax check)
  --verbose          Show field values even when matching
  --help             Show this help message

Exit codes:
  0  No drift detected
  1  Drift detected
  2  Error (missing dependencies, files, or invalid config)

Examples:
  $(basename "$0")
  $(basename "$0") --session my-session
  $(basename "$0") --file session/contract.json
  $(basename "$0") --no-knowledge --verbose
EOF
    exit 0
}

# --- Logging Helpers -------------------------------------------------------
log_header() {
    local msg="$1"
    echo -e "${CYAN}■${NC} ${msg}"
}

log_pass() {
    echo -e "  ${GREEN}✓${NC} $1"
}

log_drift() {
    echo -e "  ${YELLOW}⚠${NC} [DRIFT] $1"
}

log_error() {
    echo -e "  ${RED}✗${NC} $1" >&2
}

log_verbose() {
    if [[ "$VERBOSE" == true ]]; then
        echo -e "  ${NC}  $1"
    fi
}

# --- Parse Flags -----------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case $1 in
        --session)
            shift
            SESSION_ID="$1"
            shift
            ;;
        --file)
            shift
            CONTRACT_FILE="$1"
            shift
            ;;
        --no-knowledge)
            NO_KNOWLEDGE=true
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --help)
            HELP=true
            shift
            ;;
        *)
            echo -e "${RED}Unknown option:${NC} $1" >&2
            echo "Try '$(basename "$0") --help' for more information." >&2
            exit 2
            ;;
    esac
done

# --- Help Guard ------------------------------------------------------------
if [[ "$HELP" == true ]]; then
    usage
fi

# --- Dependency Checks -----------------------------------------------------
command -v jq >/dev/null 2>&1 || {
    log_error "jq is required but not installed."
    exit 2
}

# --- Determine Session ---
if [[ -z "$SESSION_ID" ]]; then
    SESSION_ID="session"
fi

# --- Determine Contract File -----------------------------------------------
if [[ -z "$CONTRACT_FILE" ]]; then
    CONTRACT_FILE="$PROJECT_DIR/session/contract.json"
fi

# --- Header ----------------------------------------------------------------
echo ""
log_header "drift-detect.sh — Contract Drift Check"
echo -e "   Session: ${CYAN}${SESSION_ID}${NC}"
echo ""

# --- Read Knowledge Version (KV) -------------------------------------------
KV_JSON=""
KNOWLEDGE_FOUND=false

if [[ "$NO_KNOWLEDGE" == false ]]; then
    if ! command -v lean-ctx >/dev/null 2>&1; then
        log_error "lean-ctx not available, cannot read knowledge."
        exit 2
    fi

    # Capture knowledge output (may contain "Error:" or valid JSON)
    KV_RAW="$(lean-ctx ctx_knowledge recall --key "orchestration-contract" --mode "exact" 2>/dev/null || true)"

    if echo "$KV_RAW" | jq -e . >/dev/null 2>&1; then
        KV_JSON="$KV_RAW"
        KNOWLEDGE_FOUND=true
    else
        log_error "Knowledge version not found (use --no-knowledge to skip)"
        if [[ ! -f "$CONTRACT_FILE" ]]; then
            log_error "File version not found at path: ${CONTRACT_FILE}"
            exit 2
        fi
        # Continue with file-only check
    fi
fi

# --- Read File Version (FV) ------------------------------------------------
FV_JSON=""
FILE_FOUND=false

if [[ -f "$CONTRACT_FILE" ]]; then
    FV_RAW="$(cat "$CONTRACT_FILE")"
    if echo "$FV_RAW" | jq -e . >/dev/null 2>&1; then
        FV_JSON="$FV_RAW"
        FILE_FOUND=true
    else
        log_error "Invalid JSON in file: ${CONTRACT_FILE}"
        exit 2
    fi
else
    if [[ "$NO_KNOWLEDGE" == true ]]; then
        # In no-knowledge mode, file is required for any check
        log_error "File version not found at path: ${CONTRACT_FILE}"
        exit 2
    fi
    # Without --no-knowledge, file not found is not fatal if knowledge exists
    log_error "File version not found at path: ${CONTRACT_FILE}"
    if [[ "$KNOWLEDGE_FOUND" == false ]]; then
        exit 2
    fi
fi

# --- Edge Case: Both missing -----------------------------------------------
if [[ "$KNOWLEDGE_FOUND" == false && "$FILE_FOUND" == false ]]; then
    log_error "Both knowledge and file versions are missing."
    exit 2
fi

# --- Edge Case: No file, knowledge only ------------------------------------
if [[ "$FILE_FOUND" == false && "$KNOWLEDGE_FOUND" == true ]]; then
    echo -e "   ${YELLOW}No file to compare against. Knowledge-only mode.${NC}"
    echo ""
    exit 0
fi

# --- Edge Case: No knowledge, file only ------------------------------------
if [[ "$KNOWLEDGE_FOUND" == false && "$FILE_FOUND" == true ]]; then
    echo -e "   ${YELLOW}No knowledge version to compare against. File-only mode.${NC}"
    echo ""
    exit 0
fi

# -- Compare Fields ---------------------------------------------------------

compare_field() {
    local field="$1"
    local kv_val
    local fv_val

    kv_val="$(echo "$KV_JSON" | jq -r ".${field}" 2>/dev/null || echo "__NULL__")"
    fv_val="$(echo "$FV_JSON" | jq -r ".${field}" 2>/dev/null || echo "__NULL__")"

    # Handle null vs missing
    if [[ "$kv_val" == "__NULL__" && "$fv_val" == "__NULL__" ]]; then
        log_verbose "[MATCH] ${field}: both missing/null"
        return 0
    fi

    if [[ "$kv_val" == "__NULL__" ]]; then
        kv_val="<missing>"
    fi
    if [[ "$fv_val" == "__NULL__" ]]; then
        fv_val="<missing>"
    fi

    if [[ "$kv_val" != "$fv_val" ]]; then
        DRIFT_COUNT=$((DRIFT_COUNT + 1))
        log_drift "${field}: knowledge=${kv_val}, file=${fv_val}"
    else
        log_verbose "[MATCH] ${field}: ${kv_val}"
    fi
}

# Compare all specified fields
compare_field "state"
compare_field "score.combined"
compare_field "score.verdict"
compare_field "session.task_id"
compare_field "retry.attempt"

echo ""

# --- Summary ---------------------------------------------------------------
if [[ "$DRIFT_COUNT" -eq 0 ]]; then
    echo -e "   ${GREEN}✅ No drift detected between knowledge and file versions.${NC}"
    echo ""
    exit 0
else
    echo -e "   ${YELLOW}⚠ ${DRIFT_COUNT} drift(s) detected:${NC}"
    echo -e "   Hint: Run 'scripts/self-repair.sh' to assess restoration options, or manually sync."
    echo ""
    exit 1
fi
