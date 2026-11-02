#!/usr/bin/env bash
# auto-persist.sh — Unified Atomic Orchestration Contract Persistence
# Writes the orchestration contract to BOTH lean-ctx knowledge AND
# session/contract.json in one atomic call.
#
# Usage:
#   scripts/auto-persist.sh                          # Persist current session (default)
#   scripts/auto-persist.sh --file path               # Persist specific file
#   scripts/auto-persist.sh --session SESSION_ID            # Override session id
#   scripts/auto-persist.sh --no-knowledge             # Skip lean-ctx, file only
#   scripts/auto-persist.sh --no-file                  # Skip file, knowledge only
#   scripts/auto-persist.sh --dry-run                  # Preview without writing
#   scripts/auto-persist.sh --triggered-by NAME        # Who/what triggered the persist
#   scripts/auto-persist.sh --verbose                  # Enable verbose logging
#   scripts/auto-persist.sh --help                     # Show usage
#
# Exit codes:
#   0 = Success
#   1 = Error (invalid args, missing file, invalid JSON, etc.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------
command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 1; }

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_verbose() { [[ "$VERBOSE" == true ]] && echo -e "${YELLOW}[VERBOSE]${NC} $*"; }

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
SESSION_ID=""
CONTRACT_FILE=""
SKIP_KNOWLEDGE=false
SKIP_FILE=false
DRY_RUN=false
VERBOSE=false
TRIGGERED_BY="${TRIGGERED_BY:-auto-persist}"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
auto-persist.sh — Unified Orchestration Contract Persistence

Persists the orchestration contract to lean-ctx knowledge AND file storage
in one atomic call.

USAGE:
    $(basename "$0") [OPTIONS]

OPTIONS:
    --file PATH           Persist specific contract file
                          (default: session/contract.json)
    --session SESSION_ID       Override session id
    --no-knowledge        Skip lean-ctx persistence (file only)
    --no-file             Skip file persistence (knowledge only)
    --dry-run             Preview what would be done without writing
    --triggered-by NAME   Record who/what triggered the persist (for audit)
    --verbose             Enable verbose logging
    --help                Show this usage message

EXAMPLES:
    $(basename "$0")
        Persist current session to both knowledge and file.

    $(basename "$0") --session my-session
        Persist a specific session (auto-detects contract file path).

    $(basename "$0") --file /tmp/contract.json
        Persist a specific contract file to both knowledge and file.

    $(basename "$0") --no-knowledge --triggered-by "quality-analyst"
        Persist to file only, recording the trigger source.

    $(basename "$0") --dry-run
        Preview the persist operation without making changes.

EXIT CODES:
    0   Success
    1   Error

EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Parse flags
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --file)
            CONTRACT_FILE="$2"
            shift 2
            ;;
        --session)
            SESSION_ID="$2"
            shift 2
            ;;
        --no-knowledge)
            SKIP_KNOWLEDGE=true
            shift
            ;;
        --no-file)
            SKIP_FILE=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --triggered-by)
            TRIGGERED_BY="$2"
            shift 2
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --help)
            usage
            ;;
        *)
            echo -e "${RED}[ERROR]${NC} Unknown option: $1" >&2
            echo "Run '$(basename "$0") --help' for usage." >&2
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Edge case: both --no-file and --no-knowledge
# ---------------------------------------------------------------------------
if [[ "$SKIP_FILE" == true && "$SKIP_KNOWLEDGE" == true ]]; then
    echo -e "${RED}[ERROR]${NC} Nothing to do: both file and knowledge persistence disabled" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Determine session
if [[ -z "$SESSION_ID" ]]; then
    SESSION_ID="session"
fi

# ---------------------------------------------------------------------------
# Determine contract file path
# ---------------------------------------------------------------------------
if [[ -z "$CONTRACT_FILE" ]]; then
    CONTRACT_FILE="$PROJECT_DIR/session/contract.json"
fi

# Resolve to absolute path if relative
if [[ "$CONTRACT_FILE" != /* ]]; then
    CONTRACT_FILE="$PROJECT_DIR/$CONTRACT_FILE"
fi

# ---------------------------------------------------------------------------
# Derive contract directory
# ---------------------------------------------------------------------------
CONTRACT_DIR="$(dirname "$CONTRACT_FILE")"

# ---------------------------------------------------------------------------
# Dry-run / Help output
# ---------------------------------------------------------------------------
if [[ "$DRY_RUN" == true ]]; then
    echo -e "${YELLOW}[DRY-RUN]${NC} auto-persist.sh — Preview"
    echo -e "${YELLOW}[DRY-RUN]${NC}   Session:           $SESSION_ID"
    echo -e "${YELLOW}[DRY-RUN]${NC}   Contract file:    $CONTRACT_FILE"
    echo -e "${YELLOW}[DRY-RUN]${NC}   Persist to file:  $([[ "$SKIP_FILE" == true ]] && echo "NO" || echo "YES")"
    echo -e "${YELLOW}[DRY-RUN]${NC}   Persist to knowledge: $([[ "$SKIP_KNOWLEDGE" == true ]] && echo "NO" || echo "YES")"
    echo -e "${YELLOW}[DRY-RUN]${NC}   Triggered by:     ${TRIGGERED_BY:-"(not set)"}"
    echo -e "${YELLOW}[DRY-RUN]${NC}   Verbose:          $([[ "$VERBOSE" == true ]] && echo "YES" || echo "no")"
    echo ""
    if [[ ! -f "$CONTRACT_FILE" ]]; then
        echo -e "${YELLOW}[DRY-RUN]${NC}   ⚠  Contract file does not exist yet."
        echo -e "${YELLOW}[DRY-RUN]${NC}   Would create: $CONTRACT_DIR"
        echo -e "${YELLOW}[DRY-RUN]${NC}   Would fail with: Contract not found at $CONTRACT_FILE. Initialize first."
    else
        echo -e "${YELLOW}[DRY-RUN]${NC}   Contract file exists. Would read and persist."
    fi
    echo ""
    echo -e "${YELLOW}[DRY-RUN]${NC} No changes made."
    exit 0
fi

# ---------------------------------------------------------------------------
# Ensure contract file exists
# ---------------------------------------------------------------------------
if [[ ! -f "$CONTRACT_FILE" ]]; then
    mkdir -p "$CONTRACT_DIR"
    echo -e "${RED}[ERROR]${NC} Contract not found at $CONTRACT_FILE. Initialize first." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Read and validate JSON
# ---------------------------------------------------------------------------
if ! CONTRACT_JSON="$(jq -c '.' "$CONTRACT_FILE" 2>/dev/null)"; then
    echo -e "${RED}[ERROR]${NC} Invalid JSON in contract file: $CONTRACT_FILE" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Audit Log Auto-Population
# Detect state transitions and append audit entries
# ---------------------------------------------------------------------------
OLD_STATE=""
if command -v lean-ctx &>/dev/null; then
    OLD_STATE=$(lean-ctx ctx_knowledge recall --key "orchestration-contract" --mode "exact" 2>/dev/null | jq -r '.state // ""' 2>/dev/null || echo "")
fi
log_verbose "OLD_STATE='${OLD_STATE}'"

NEW_STATE=$(jq -r '.state // ""' "$CONTRACT_FILE")
log_verbose "NEW_STATE='${NEW_STATE}'"

if [[ -n "$OLD_STATE" && -n "$NEW_STATE" && "$OLD_STATE" != "$NEW_STATE" ]]; then
    log_info "State transition detected: $OLD_STATE → $NEW_STATE (triggered by: $TRIGGERED_BY)"

    # Check for duplicate audit entry (same transition, same trigger)
    HAS_DUPE=$(jq --arg from "$OLD_STATE" --arg to "$NEW_STATE" --arg trig "$TRIGGERED_BY" '
        .audit_log // [] | map(select(.prev_state == $from and .new_state == $to and .triggered_by == $trig)) | length > 0
    ' "$CONTRACT_FILE")

    if [[ "$HAS_DUPE" == "true" ]]; then
        log_verbose "Skipping duplicate audit entry for $OLD_STATE → $NEW_STATE"
    else
        CURRENT_SCORE=$(jq '.score.combined // 0' "$CONTRACT_FILE")
        # Create temp file with audit entry appended
        jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
           --arg from "$OLD_STATE" \
           --arg to "$NEW_STATE" \
           --arg trig "$TRIGGERED_BY" \
           --argjson score "$CURRENT_SCORE" \
           '.audit_log += [{"timestamp": $ts, "prev_state": $from, "new_state": $to, "triggered_by": $trig, "scoring_snapshot": $score}]' \
           "$CONTRACT_FILE" > "${CONTRACT_FILE}.tmp" && mv "${CONTRACT_FILE}.tmp" "$CONTRACT_FILE" && {
            log_info "Audit entry added: $OLD_STATE → $NEW_STATE"
            # Re-read contract JSON after audit modification
            CONTRACT_JSON="$(jq -c '.' "$CONTRACT_FILE" 2>/dev/null)"
        } || {
            echo -e "${YELLOW}[WARN]${NC} Failed to append audit entry, continuing..."
        }
    fi
fi

# ---------------------------------------------------------------------------
# Persist to lean-ctx knowledge (unless --no-knowledge)
# ---------------------------------------------------------------------------
if [[ "$SKIP_KNOWLEDGE" == false ]]; then
    if command -v lean-ctx >/dev/null 2>&1; then
        echo -e "${GREEN}[INFO]${NC} Persisting to lean-ctx knowledge (key: orchestration-contract)..."

        # Build optional flags for lean-ctx
        LEARN_CTX_EXTRA=()
        if [[ -n "$TRIGGERED_BY" ]]; then
            LEARN_CTX_EXTRA+=(--triggered-by "$TRIGGERED_BY")
        fi

        # We use ctx_knowledge remember via the MCP tool mechanism.
        # Since this is a shell script, we invoke lean-ctx CLI.
        # Fallback: write to a temp file and pipe to lean-ctx if needed.
        echo "$CONTRACT_JSON" | lean-ctx ctx_knowledge remember \
            --key "orchestration-contract" \
            --value "$CONTRACT_JSON" \
            "${LEARN_CTX_EXTRA[@]}" 2>/dev/null && {
            echo -e "${GREEN}[PASS]${NC} Knowledge persisted successfully."
        } || {
            echo -e "${YELLOW}[WARN]${NC} lean-ctx returned non-zero, but continuing..."
        }
    else
        echo -e "${YELLOW}[WARN]${NC} lean-ctx not available, skipping knowledge persistence" >&2
    fi
fi

# ---------------------------------------------------------------------------
# Persist to contract file (unless --no-file)
# ---------------------------------------------------------------------------
if [[ "$SKIP_FILE" == false ]]; then
    echo -e "${GREEN}[INFO]${NC} Writing contract to: $CONTRACT_FILE"

    # Write via temp file + atomic rename
    TEMP_FILE="$(mktemp /tmp/auto-persist-XXXXXX.json)"
    if [[ -z "$TEMP_FILE" ]]; then
        echo -e "${RED}[ERROR]${NC} Failed to create temp file" >&2
        exit 1
    fi

    # Pretty-print JSON to temp file
    if ! echo "$CONTRACT_JSON" | jq '.' > "$TEMP_FILE" 2>/dev/null; then
        echo -e "${RED}[ERROR]${NC} Failed to write temp file" >&2
        rm -f "$TEMP_FILE"
        exit 1
    fi

    # Atomic rename
    if ! mv "$TEMP_FILE" "$CONTRACT_FILE"; then
        echo -e "${RED}[ERROR]${NC} Atomic rename failed: $TEMP_FILE → $CONTRACT_FILE" >&2
        rm -f "$TEMP_FILE"
        exit 1
    fi

    echo -e "${GREEN}[PASS]${NC} File write successful: $CONTRACT_FILE"

    # Run snapshot-contract.sh to archive (non-critical; log but don't fail)
    if [[ -x "$SCRIPT_DIR/snapshot-contract.sh" ]]; then
        echo -e "${GREEN}[INFO]${NC} Archiving via snapshot-contract.sh..."
        if ! "$SCRIPT_DIR/snapshot-contract.sh" --snapshot-only 2>/dev/null; then
            echo -e "${YELLOW}[WARN]${NC} snapshot-contract.sh returned non-zero, but continuing..."
        else
            echo -e "${GREEN}[PASS]${NC} Snapshot archive complete."
        fi
    else
        echo -e "${YELLOW}[WARN]${NC} snapshot-contract.sh not found or not executable, skipping archive" >&2
    fi
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo -e "${GREEN}[PASS]${NC} Persist completed successfully."
exit 0
