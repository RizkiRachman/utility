#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# snapshot-contract.sh — Validate and snapshot the orchestration contract state.
#
# Single-session model: live state lives at session/contract.json and the
# append-only transition history lives at session/state.md. Idempotent — safe
# to run multiple times.
#
# Usage:
#   ./scripts/snapshot-contract.sh                 # Snapshot current session
#   ./scripts/snapshot-contract.sh --help          # Show usage
#   ./scripts/snapshot-contract.sh --dry-run       # Show what would be done
#   ./scripts/snapshot-contract.sh --verbose       # Detailed output
#   ./scripts/snapshot-contract.sh --snapshot-only  # Validate only, skip state.md
#   ./scripts/snapshot-contract.sh --summary TEXT  # Custom summary text
#   ./scripts/snapshot-contract.sh --archive       # Tarball archive of session/
#
# Exit codes:
#   0 — Snapshot created successfully
#   1 — Error
#   2 — Usage displayed
#
# Requirements:
#   - bash 4+
#   - jq (for extracting state/score from session/contract.json)

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SESSION_DIR="$PROJECT_ROOT/session"
CONTRACT_FILE="$SESSION_DIR/contract.json"

# ── Config ──────────────────────────────────────────────────────────────────
VERBOSE=false
DRY_RUN=false
SNAPSHOT_ONLY=false
SUMMARY_TEXT="Snapshot"
ARCHIVE_MODE=false
SESSION_LABEL="session"
EXIT_CODE=0

# Color output (disable if not a terminal)
if [[ -t 1 ]]; then
    GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
else
    GREEN=''; RED=''; YELLOW=''; CYAN=''; NC=''
fi

# ── Help ────────────────────────────────────────────────────────────────────
usage() {
    cat <<'USAGE'
snapshot-contract.sh — Validate and snapshot the orchestration contract state

SYNOPSIS
    ./scripts/snapshot-contract.sh [OPTIONS]

OPTIONS
    --help            Show this help message and exit
    --dry-run         Show what would be done without modifying anything
    --verbose         Print detailed output for each operation
    --snapshot-only   Only validate session state, skip state.md updates
    --session ID      Label the snapshot with a session id (default: session)
    --summary TEXT    Custom summary text for the state.md entry
    --archive         Create a tarball archive of session/ in archived-sessions/

BEHAVIOR
    1. Ensures session/ exists (initializes from contract templates if needed)
    2. Validates session state at session/contract.json
    3. Appends a transition entry to session/state.md
    4. Optionally archives session/ as a tarball

SOURCE FILES
    session/contract.json              (live state)
    contract/contract.template.json    (seed template)
    contract/state.template.md         (seed template)

EXIT CODES
    0   Snapshot created successfully
    1   Error
    2   Usage displayed

EXAMPLES
    ./scripts/snapshot-contract.sh
    ./scripts/snapshot-contract.sh --verbose
    ./scripts/snapshot-contract.sh --dry-run
    ./scripts/snapshot-contract.sh --summary "Post-review snapshot"
    ./scripts/snapshot-contract.sh --archive
USAGE
    exit 2
}

# ── Logging ─────────────────────────────────────────────────────────────────
log_pass()    { echo -e "${GREEN}[PASS]${NC} $1"; }
log_fail()    { EXIT_CODE=1; echo -e "${RED}[FAIL]${NC} $1"; }
log_info()    { [[ "$VERBOSE" == true ]] && echo -e "${YELLOW}[INFO]${NC} $1" || true; }
log_verbose() { [[ "$VERBOSE" == true ]] && echo "  :: $1" || true; }
log_dry()     { echo -e "${CYAN}[DRY-RUN]${NC} $1"; }

# ── Helpers ─────────────────────────────────────────────────────────────────
get_date() { date -u +"%Y-%m-%d"; }
get_timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# Compute SHA-256 hex digest of a file
compute_hash() {
    local file="$1"
    [[ -f "$file" ]] || { echo "missing"; return 1; }
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | cut -d' ' -f1
    elif command -v openssl >/dev/null 2>&1; then
        openssl sha256 "$file" | cut -d' ' -f2
    else
        echo "unavailable"; return 1
    fi
}

# ── Core Operations ─────────────────────────────────────────────────────────

# Ensure session/ is initialized from the contract templates.
init_session() {
    local tpl="$PROJECT_ROOT/contract/contract.template.json"
    if [[ ! -f "$tpl" ]]; then
        log_fail "contract/contract.template.json not found — nothing to snapshot"
        exit 1
    fi
    if [[ -f "$CONTRACT_FILE" ]]; then
        log_verbose "Session state already initialized"
        return 0
    fi
    if [[ "$DRY_RUN" == true ]]; then
        log_dry "Would initialize session state in $SESSION_DIR"
        return 0
    fi
    mkdir -p "$SESSION_DIR"
    cp "$tpl" "$CONTRACT_FILE"
    [[ -f "$PROJECT_ROOT/contract/state.template.md" ]] && cp "$PROJECT_ROOT/contract/state.template.md" "$SESSION_DIR/state.md"
    [[ -f "$PROJECT_ROOT/contract/contract.schema.json" ]] && cp "$PROJECT_ROOT/contract/contract.schema.json" "$SESSION_DIR/contract.schema.json"
    log_info "Initialized session state in $SESSION_DIR"
}

# Append a transition entry to session/state.md
update_state_log() {
    local state="$1" score="$2" hash="$3"
    local state_file="$SESSION_DIR/state.md"
    if [[ "$DRY_RUN" == true ]]; then
        log_dry "Would append transition ($state, $score) to $state_file"
        return 0
    fi
    if [[ ! -f "$state_file" ]]; then
        printf '# Session State History\n\n| Timestamp | Session | State | Score | Hash | Summary |\n|---|---|---|---|---|---|\n' > "$state_file"
    fi
    printf '| %s | %s | %s | %s | %s | %s |\n' \
        "$(get_timestamp)" "$SESSION_LABEL" "$state" "$score" "${hash:0:12}" "$SUMMARY_TEXT" >> "$state_file"
    log_pass "Appended transition to $state_file"
}

# Optional tarball archive of session/
archive_session() {
    local archive_dir="$PROJECT_ROOT/archived-sessions"
    local archive_path="$archive_dir/session-$(get_date).tar.gz"
    if [[ "$DRY_RUN" == true ]]; then
        log_dry "Would create archive: $archive_path"
        return 0
    fi
    mkdir -p "$archive_dir"
    if tar -C "$SESSION_DIR" -czf "$archive_path" . 2>/dev/null; then
        log_pass "Archive created: $(basename "$archive_path") ($(wc -c < "$archive_path" | tr -d ' ') bytes)"
    else
        log_fail "Failed to create archive: $archive_path"
    fi
}
