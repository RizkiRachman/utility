#!/usr/bin/env bash
# =============================================================================
# self-repair.sh — Detect corrupt contract.json, restore from valid snapshot
#
# Detects corrupt contract.json, finds the latest valid snapshot from
# session/, restores it, re-validates, and reports.
#
# Usage:
#   scripts/self-repair.sh                           # Auto-detect session, check
#   scripts/self-repair.sh --file session/b/contract.json  # Specific file
#   scripts/self-repair.sh --dry-run                 # Show what would be restored
#   scripts/self-repair.sh --force                   # Skip user confirmation
#   scripts/self-repair.sh --restore SNAPSHOT        # Restore from specific path
#   scripts/self-repair.sh --help
#
# Exit codes:
#   0 — Contract valid or successfully restored
#   1 — Corruption detected, no valid snapshots
#   2 — Usage displayed
#   3 — Missing dependency
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Config ──────────────────────────────────────────────────────────────────
CONTRACT_FILE=""
SESSION_ID=""
DRY_RUN=false
FORCE=false
RESTORE_PATH=""
VERBOSE=false
EXIT_CODE=0

# Color output (disable if not a terminal)
if [[ -t 1 ]]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    NC='\033[0m'
else
    GREEN=''
    RED=''
    YELLOW=''
    CYAN=''
    NC=''
fi

# ── Help ────────────────────────────────────────────────────────────────────
usage() {
    cat <<'USAGE'
self-repair.sh — Repair corrupt contract.json from session snapshots

SYNOPSIS
    ./scripts/self-repair.sh [OPTIONS]

OPTIONS
    --help              Show this help message and exit
    --file PATH         Contract JSON file to check (default: auto-detect)
    --dry-run           Show what would be restored without modifying anything
    --force             Restore without user confirmation
    --restore PATH      Restore from a specific snapshot file path
    --verbose           Show detailed output

BEHAVIOR
    1. Determines session (from the session, or from --file parent dir)
    2. Validates current contract via validate-contract.sh --score
    3. If valid — reports success, exits 0
    4. If corrupt — scans session/ for snapshot files
    5. Finds the newest valid snapshot
    6. Restores it (with confirmation unless --force)

SOURCE FILES
    session/contract.json          (live state — target for repair)
    session/contract.*.json        (snapshots to search)

EXIT CODES
    0   Contract valid or successfully restored
    1   Corruption detected, no valid snapshots
    2   Usage displayed
    3   Missing dependency

EXAMPLES
    ./scripts/self-repair.sh
    ./scripts/self-repair.sh --file session/xxx/contract.json
    ./scripts/self-repair.sh --dry-run
    ./scripts/self-repair.sh --force
USAGE
    exit 2
}

# ── Logging ─────────────────────────────────────────────────────────────────
log_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
}

log_fail() {
    EXIT_CODE=1
    echo -e "${RED}[FAIL]${NC} $1"
}

log_info() {
    echo -e "${YELLOW}[INFO]${NC} $1" >&2
}

log_verbose() {
    if [[ "$VERBOSE" == true ]]; then
        echo -e "${CYAN}[VERB]${NC} $1" >&2
    fi
}

log_dry() {
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "  ${YELLOW}(dry-run)${NC} $1" >&2
    fi
}

# ── Dependency Checks ───────────────────────────────────────────────────────
check_deps() {
    if ! command -v jq &>/dev/null; then
        log_fail "jq is required but not installed."
        exit 3
    fi

    local validator="$SCRIPT_DIR/validate-contract.sh"
    if [[ ! -f "$validator" ]]; then
        log_fail "validate-contract.sh helper not found at: $validator"
        exit 3
    fi
}

# ── Validate Contract ───────────────────────────────────────────────────────
validate_contract() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        echo "FILE_NOT_FOUND"
        return 1
    fi
    if [[ "$DRY_RUN" == true ]]; then
        # Dry-run: quick structural validation only (jq parse check)
        if jq -e . "$file" &>/dev/null; then
            echo "VALID(score=0)"
            return 0
        else
            echo "INVALID"
            return 1
        fi
    fi
    # Full validation via validate-contract.sh
    # Capture exit code BEFORE || true resets $?
    local exit_code=0
    local output
    output="$("$SCRIPT_DIR/validate-contract.sh" --file "$file" --score 2>/dev/null)" && exit_code=0 || exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        # Extract score from output
        local score
        score="$(echo "$output" | grep -oE '[0-9]+' | head -1 || echo "0")"
        echo "VALID(score=${score:-0})"
        return 0
    else
        # Extract score even on failure
        local score
        score="$(echo "$output" | grep -oE '[0-9]+' | head -1 || echo "0")"
        echo "INVALID(score=${score:-0})"
        return 1
    fi
}

# ── Determine Session ────────────────────────────────────────────────────────
detect_session() {
    # If session already set from --file path, use it
    if [[ -n "$SESSION_ID" ]]; then
        echo "$SESSION_ID"
        return 0
    fi

    local session
    session="$(echo session 2>/dev/null)" || true
    if [[ -z "$session" ]]; then
        log_fail "Session not resolved."
        log_info "Use --file to specify the contract path explicitly."
        exit 1
    fi
    echo "$session"
}

# ── Extract Session from Path ────────────────────────────────────────────────
session_from_path() {
    local path="$1"
    # Normalize path (remove trailing slash)
    path="${path%/}"
    # Match session/something/contract.json
    if [[ "$path" =~ session/(.+)/contract\.json$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    # Try session/something/anything
    local dir
    dir="$(dirname "$path")"
    if [[ "$dir" =~ session/(.+) ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    # Last resort: parent directory name
    basename "$(dirname "$path")"
}

# ── Scan Snapshots ──────────────────────────────────────────────────────────
scan_snapshots() {
    local session="$1"
    local session_dir="$PROJECT_ROOT/session"

    if [[ ! -d "$session_dir" ]]; then
        log_info "No session archive found for session '$session'"
        log_info "  Path: $session_dir"
        return 1
    fi

    if [[ "$VERBOSE" == true ]]; then
        log_info "Scanning $session_dir for snapshots..."
    fi

    # Find all contract*.json files, sorted by modification time (newest first)
    local raw_snapshots=()
    while IFS= read -r -d '' f; do
        raw_snapshots+=("$f")
    done < <(find "$session_dir" -maxdepth 1 -name 'contract*.json' -type f -print0 2>/dev/null)

    if [[ ${#raw_snapshots[@]} -eq 0 ]]; then
        log_info "No snapshots found in $session_dir"
        return 1
    fi

    # Sort by modification time (newest first) using ls -t
    local sorted_paths=()
    while IFS= read -r line; do
        sorted_paths+=("$line")
    done < <(ls -1t "${raw_snapshots[@]}" 2>/dev/null || true)

    if [[ ${#sorted_paths[@]} -eq 0 ]]; then
        log_info "No snapshots found (after sorting) in $session_dir"
        return 1
    fi

    # Filter out known structural non-contract-state files
    local filtered=()
    for snap in "${sorted_paths[@]}"; do
        local basename
        basename="$(basename "$snap")"
        case "$basename" in
            contract.schema.json|contract.template.json)
                log_verbose "Skipping structural file: $basename"
                continue
                ;;
        esac
        # Normalize path: ensure absolute
        if [[ "$snap" != /* ]]; then
            snap="$session_dir/$snap"
        fi
        filtered+=("$snap")
    done

    if [[ ${#filtered[@]} -eq 0 ]]; then
        log_info "No snapshots found (after filtering) in $session_dir"
        return 1
    fi

    # Output: first line = count, rest = paths
    echo "${#filtered[@]}"
    printf '%s\n' "${filtered[@]}"
    return 0
}

# ── Main ────────────────────────────────────────────────────────────────────
main() {
    # Parse flags
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help)
                usage
                ;;
            --file)
                if [[ -z "${2:-}" ]]; then
                    log_fail "--file requires a path argument"
                    exit 2
                fi
                CONTRACT_FILE="$2"
                SESSION_ID="$(session_from_path "$CONTRACT_FILE")"
                shift 2
                ;;
            --file=*)
                CONTRACT_FILE="${1#*=}"
                SESSION_ID="$(session_from_path "$CONTRACT_FILE")"
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --force)
                FORCE=true
                shift
                ;;
            --restore)
                if [[ -z "${2:-}" ]]; then
                    log_fail "--restore requires a path argument"
                    exit 2
                fi
                RESTORE_PATH="$2"
                shift 2
                ;;
            --restore=*)
                RESTORE_PATH="${1#*=}"
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            *)
                log_fail "Unknown option: $1"
                echo "Use --help for usage."
                exit 2
                ;;
        esac
    done

    # Check dependencies
    check_deps

    # Determine session if not set
    if [[ -z "$SESSION_ID" ]]; then
        SESSION_ID="$(detect_session)"
    fi
    log_verbose "Detected session: $SESSION_ID"

    # Determine contract file if not set
    if [[ -z "$CONTRACT_FILE" ]]; then
        CONTRACT_FILE="$PROJECT_ROOT/session/contract.json"
    fi
    log_verbose "Contract file: $CONTRACT_FILE"

    echo ""
    echo "━━━ self-repair.sh — Contract Health Check ━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "   Session: $SESSION_ID"
    echo "   File:   $CONTRACT_FILE"
    echo ""

    # ── Handle --restore ───────────────────────────────────────────────────
    if [[ -n "$RESTORE_PATH" ]]; then
        if [[ ! -f "$RESTORE_PATH" ]]; then
            log_fail "Specified snapshot not found: $RESTORE_PATH"
            exit 1
        fi
        local result
        result="$(validate_contract "$RESTORE_PATH")" || true
        if [[ "$result" == INVALID* ]]; then
            local score="${result##*(score=}"
            score="${score%)}"
            log_fail "Specified snapshot is not valid (score: $score)"
            exit 1
        fi
        if [[ "$DRY_RUN" == true ]]; then
            log_dry "Would restore from: $RESTORE_PATH"
            log_dry "  → Would copy to: $CONTRACT_FILE"
            # Show diff preview if diff available
            if command -v diff &>/dev/null && [[ -f "$CONTRACT_FILE" ]]; then
                log_dry "  Diff preview (current → snapshot):"
                diff -u "$CONTRACT_FILE" "$RESTORE_PATH" 2>/dev/null | head -40 || true
            fi
            echo ""
            log_pass "Dry-run complete. Use --force to restore."
            exit 0
        fi
        # Confirm unless --force
        if [[ "$FORCE" != true ]]; then
            echo "   Found valid snapshot: $RESTORE_PATH"
            echo "   Use --force to restore."
            exit 0
        fi
        # Restore
        cp "$RESTORE_PATH" "$CONTRACT_FILE"
        echo "   ✅ Copied $RESTORE_PATH → $CONTRACT_FILE"
        # Re-validate restored
        local recheck
        recheck="$(validate_contract "$CONTRACT_FILE")" || true
        if [[ "$recheck" == VALID* ]]; then
            local score="${recheck##*(score=}"
            score="${score%)}"
            log_pass "Restored from valid snapshot: $RESTORE_PATH (score: $score)"
            exit 0
        else
            log_fail "Restored contract is invalid — something went wrong."
            exit 1
        fi
    fi

    # ── Step 3: Validate current contract ──────────────────────────────────
    local contract_exists=true
    if [[ ! -f "$CONTRACT_FILE" ]]; then
        contract_exists=false
        log_info "Contract file does not exist: $CONTRACT_FILE"
        echo "   Status: ❌ File not found"
    fi

    if [[ "$contract_exists" == true ]]; then
        local current_result
        current_result="$(validate_contract "$CONTRACT_FILE")" || true
        if [[ "$current_result" == VALID* ]]; then
            local score="${current_result##*(score=}"
            score="${score%)}"
            echo "   Status: ✅ Valid (passed validate-contract.sh)"
            if [[ -n "$score" && "$score" != "0" ]]; then
                echo "   Score:  $score/100"
            fi
            echo ""
            log_pass "self-repair.sh — Contract valid, no repair needed."
            exit 0
        fi
        local current_score="${current_result##*(score=}"
        current_score="${current_score%)}"
        echo "   Status: ❌ Validation failed (score: ${current_score:-N/A})"
        echo ""
    fi

    # ── Step 4-5: Scan for snapshots ───────────────────────────────────────
    echo "   Scanning session/ for snapshots..."
    local scan_result
    scan_result="$(scan_snapshots "$SESSION_ID")" || true

    if [[ -z "$scan_result" ]]; then
        echo "   ⚠  No snapshots found."
        echo "   Status: ❌ No valid snapshots available for restoration."
        echo ""
        log_fail "No valid snapshots available for restoration."
        echo "   Manual repair needed. Initialize from contract/contract.template.json"
        exit 1
    fi

    # Parse scan result: first line is count, rest are paths
    local snapshot_count
    snapshot_count="$(echo "$scan_result" | head -1)"
    local snapshot_files=()
    while IFS= read -r line; do
        snapshot_files+=("$line")
    done < <(echo "$scan_result" | tail -n +2)

    echo "   Found $snapshot_count snapshot candidates"
    echo ""

    # ── Validate each snapshot ────────────────────────────────────────────
    local best_candidate=""
    local best_score=0
    local candidate_index=0

    for snap in "${snapshot_files[@]}"; do
        candidate_index=$((candidate_index + 1))
        local result
        result="$(validate_contract "$snap")" || true

        if [[ "$result" == VALID* ]]; then
            local score="${result##*(score=}"
            score="${score%)}"
            if [[ -z "$score" || "$score" == "0" ]]; then
                # Dry-run only does basic jq check, set a nominal score
                score="?"
            fi
            echo "   ✅ Snapshot $candidate_index valid: $snap (score: $score)"
            # Track best (first valid = newest due to ls -t sort)
            if [[ -z "$best_candidate" ]]; then
                best_candidate="$snap"
                best_score="$score"
            fi
        else
            local score="${result##*(score=}"
            score="${score%)}"
            if [[ "$result" == "FILE_NOT_FOUND" ]]; then
                echo "   ⚠  Snapshot $candidate_index invalid: $snap (could not validate)"
            else
                echo "   ⚠  Snapshot $candidate_index invalid: $snap (score: $score)"
            fi
        fi
    done

    echo ""

    # ── Pick and restore ────────────────────────────────────────────────
    if [[ -z "$best_candidate" ]]; then
        echo "   Status: ❌ No valid snapshots available for restoration."
        echo ""
        log_fail "No valid snapshots available for restoration."
        echo "   Manual repair needed. Initialize from contract/contract.template.json"
        exit 1
    fi

    echo "   Best restore candidate: $best_candidate (score: $best_score)"

    # --dry-run
    if [[ "$DRY_RUN" == true ]]; then
        log_dry "Would restore: $best_candidate → $CONTRACT_FILE"
        if command -v diff &>/dev/null && [[ -f "$CONTRACT_FILE" ]]; then
            echo ""
            log_dry "Diff preview (current → snapshot):"
            diff -u "$CONTRACT_FILE" "$best_candidate" 2>/dev/null | head -40 || true
        fi
        echo ""
        log_pass "Dry-run complete. Use --force to restore."
        exit 0
    fi

    # Confirm unless --force
    if [[ "$FORCE" != true ]]; then
        echo ""
        echo "   Found valid snapshot: $best_candidate"
        echo "   Use --force to restore."
        exit 0
    fi

    # Restore
    echo ""
    cp "$best_candidate" "$CONTRACT_FILE"
    echo "   ✅ Copied $best_candidate → $CONTRACT_FILE"
    echo ""

    # Re-validate restored
    local recheck
    recheck="$(validate_contract "$CONTRACT_FILE")" || true
    if [[ "$recheck" == VALID* ]]; then
        local final_score="${recheck##*(score=}"
        final_score="${final_score%)}"
        log_pass "Restored from valid snapshot: $best_candidate (score: $final_score)"
        exit 0
    else
        log_fail "Restored contract is invalid — something went wrong."
        log_info "Try manual restore or initialize from contract/contract.template.json"
        exit 1
    fi
}

main "$@"
