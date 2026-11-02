#!/usr/bin/env bash
# shellcheck disable=SC2086
# archive-sessions.sh — Archive and manage old lean-ctx session files
#
#   ./scripts/archive-sessions.sh                    # Archive sessions older than 30 days
#   ./scripts/archive-sessions.sh --days 60          # Archive sessions older than 60 days
#   ./scripts/archive-sessions.sh --dry-run          # Show what would be archived
#   ./scripts/archive-sessions.sh --restore foo.tar.gz  # Restore a specific archive
#   ./scripts/archive-sessions.sh --list             # List available archives
#   ./scripts/archive-sessions.sh --verbose          # Detailed output
#   ./scripts/archive-sessions.sh --help             # Show usage
#
# Exit codes:
#   0 — Success (archive created / restored / listed / dry-run OK)
#   1 — Error (no sessions dir, bad archive, missing file)
#   2 — Usage (--help shown)
#
# Requirements:
#   - bash 4+
#   - tar, gzip (macOS bundled)
#   - lean-ctx session files in ~/.lean-ctx/sessions/
#
# This script is idempotent — safe to run multiple times.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHIVE_DIR="$PROJECT_ROOT/archived-sessions"
SESSION_DIR="${HOME}/.lean-ctx/sessions"
DRY_RUN=false
DAYS_OLD=30
VERBOSE=false
RESTORE_ARCHIVE=""
LIST_ONLY=false
EXIT_CODE=0

# Color output (disable if not a terminal)
if [[ -t 1 ]]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
fi

# ── Helper Functions ────────────────────────────────────────────────────────

usage() {
    cat <<'USAGE'
usage: archive-sessions.sh [OPTIONS]

Archive and manage old lean-ctx session files.

OPTIONS:
  --help              Show this help message and exit
  --days N            Archive sessions older than N days (default: 30)
  --dry-run           Show what would be archived without doing it
  --restore ARCHIVE   Restore a specific archive from archived-sessions/
  --list              List available archives in archived-sessions/
  --verbose           Print detailed output for each step

CHECKS:
  1. Locate session directory (~/.lean-ctx/sessions/)
  2. Find session files older than N days
  3. Create archive in archived-sessions/sessions-archive-YYYYMMDD.tar.gz
  4. (Optional) Restore an archive to the sessions directory
  5. (Optional) List all available archives

EXIT CODES:
  0   Success
  1   Error (no sessions dir, bad archive, etc.)
  2   Usage displayed

EXAMPLES:
  ./scripts/archive-sessions.sh
  ./scripts/archive-sessions.sh --days 60
  ./scripts/archive-sessions.sh --dry-run --verbose
  ./scripts/archive-sessions.sh --restore sessions-archive-20260601.tar.gz
  ./scripts/archive-sessions.sh --list
USAGE
    exit 2
}

log_pass() {
    local msg="$1"
    echo -e "${GREEN}[PASS]${NC} $msg"
}

log_fail() {
    local msg="$1"
    echo -e "${RED}[FAIL]${NC} $msg"
    EXIT_CODE=1
}

log_info() {
    local msg="$1"
    if [[ "$VERBOSE" == true ]]; then
        echo -e "${YELLOW}[INFO]${NC} $msg"
    fi
}

log_dry() {
    local msg="$1"
    echo -e "${BLUE}[DRY-RUN]${NC} $msg"
}

log_verbose() {
    local msg="$1"
    if [[ "$VERBOSE" == true ]]; then
        echo -e "  ${NC}→ $msg"
    fi
}

# ── Check 1: Locate session directory ──────────────────────────────────────

check_session_dir() {
    echo "Check 1: Locate session directory"
    if [[ -d "$SESSION_DIR" ]]; then
        log_pass "Session directory found: $SESSION_DIR"
        log_verbose "$(find "$SESSION_DIR" -maxdepth 1 -type f \( -name '*.json' -o -name '*.txt' \) 2>/dev/null | wc -l | tr -d ' ') session files present"
        return 0
    fi
    local fallback="$PROJECT_ROOT/.lean-ctx/sessions"
    if [[ -d "$fallback" ]]; then
        SESSION_DIR="$fallback"
        log_pass "Session directory found (project-local): $SESSION_DIR"
        log_verbose "$(find "$SESSION_DIR" -maxdepth 1 -type f \( -name '*.json' -o -name '*.txt' \) 2>/dev/null | wc -l | tr -d ' ') session files present"
        return 0
    fi
    log_fail "No session directory found at ~/.lean-ctx/sessions/ or .lean-ctx/sessions/"
    return 1
}

# ── Check 2: Find old session files ────────────────────────────────────────

find_old_sessions() {
    echo "Check 2: Find session files older than $DAYS_OLD days"
    local old_files=()
    local cutoff

    # macOS-compatible date math: use -v flag or fallback
    if date -v -1d >/dev/null 2>&1; then
        # macOS date
        cutoff=$(date -v -"${DAYS_OLD}"d '+%Y%m%d' 2>/dev/null)
    else
        # Linux / GNU date
        cutoff=$(date -d "$DAYS_OLD days ago" '+%Y%m%d' 2>/dev/null)
    fi

    if [[ -z "$cutoff" ]]; then
        log_fail "Could not compute cutoff date (check 'date' compatibility)"
        return 1
    fi
    log_verbose "Cutoff date: $cutoff (sessions older than ${DAYS_OLD} days)"

    # Find session files older than cutoff by comparing file mtime
    local now_epoch
    now_epoch=$(date '+%s')
    local cutoff_epoch=$((now_epoch - DAYS_OLD * 86400))

    while IFS= read -r -d '' f; do
        local mtime
        # macOS stat vs Linux stat
        if stat -f '%m' "$f" >/dev/null 2>&1; then
            mtime=$(stat -f '%m' "$f" 2>/dev/null)
        else
            mtime=$(stat -c '%Y' "$f" 2>/dev/null)
        fi
        if [[ -n "$mtime" && "$mtime" -lt "$cutoff_epoch" ]]; then
            old_files+=("$f")
        fi
    done < <(find "$SESSION_DIR" -maxdepth 1 -type f \( -name '*.json' -o -name '*.txt' \) -print0 2>/dev/null)

    if [[ ${#old_files[@]} -eq 0 ]]; then
        log_info "No session files older than $DAYS_OLD days found"
        return 1
    fi

    log_pass "Found ${#old_files[@]} session file(s) older than $DAYS_OLD days"
    if [[ "$VERBOSE" == true ]]; then
        for f in "${old_files[@]}"; do
            local fname
            fname="$(basename "$f")"
            local fsize
            fsize=$(wc -c < "$f" | tr -d ' ')
            echo "  → $fname ($fsize bytes)"
        done
    fi

    OLD_SESSION_FILES=("${old_files[@]}")
    return 0
}

# ── Check 3: Create archive ────────────────────────────────────────────────

create_archive() {
    echo "Check 3: Create archive"
    local archive_name
    local today
    local archive_path

    if date '+%Y%m%d' >/dev/null 2>&1; then
        today=$(date '+%Y%m%d')
    else
        log_fail "Cannot determine today's date"
        return 1
    fi

    archive_name="sessions-archive-${today}.tar.gz"
    archive_path="$ARCHIVE_DIR/$archive_name"

    if [[ ! -d "$ARCHIVE_DIR" ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            log_dry "Would create archive directory: $ARCHIVE_DIR"
        else
            mkdir -p "$ARCHIVE_DIR"
            log_pass "Created archive directory: $ARCHIVE_DIR"
        fi
    fi

    if [[ -f "$archive_path" ]] && [[ "$DRY_RUN" == false ]]; then
        log_info "Archive already exists: $archive_name (will append — tar -r is not safe with .tar.gz, skipping)"
        log_fail "Archive $archive_name already exists — remove it first or use --days to adjust scope"
        return 1
    fi

    if [[ ${#OLD_SESSION_FILES[@]} -eq 0 ]]; then
        log_info "No files to archive — skipping"
        return 0
    fi

    # Build file list (relative basenames since tar stores paths)
    local tmp_list
    tmp_list=$(mktemp /tmp/archive-sessions.XXXXXX) || {
        log_fail "Failed to create temporary file list"
        return 1
    }

    for f in "${OLD_SESSION_FILES[@]}"; do
        echo "$(basename "$f")" >> "$tmp_list"
    done

    if [[ "$DRY_RUN" == true ]]; then
        log_dry "Would create archive: $archive_path"
        log_dry "Would archive ${#OLD_SESSION_FILES[@]} file(s) from $SESSION_DIR"
        if [[ "$VERBOSE" == true ]]; then
            for f in "${OLD_SESSION_FILES[@]}"; do
                echo "  [DRY] → $(basename "$f")"
            done
        fi
        rm -f "$tmp_list"
        return 0
    fi

    # Create archive: change to sessions dir, tar with gzip
    log_verbose "Creating archive: $archive_path"
    if tar -C "$SESSION_DIR" -czf "$archive_path" -T "$tmp_list" 2>/dev/null; then
        local archive_size
        archive_size=$(wc -c < "$archive_path" | tr -d ' ')
        log_pass "Archive created: $archive_name ($archive_size bytes, ${#OLD_SESSION_FILES[@]} files)"

        # Remove originals only if archive was successfully created
        local removed=0
        for f in "${OLD_SESSION_FILES[@]}"; do
            if rm -f "$f"; then
                removed=$((removed + 1))
            fi
        done
        log_verbose "Removed $removed original session file(s) from $SESSION_DIR"
        rm -f "$tmp_list"
        return 0
    else
        log_fail "Failed to create archive: $archive_path"
        rm -f "$tmp_list"
        return 1
    fi
}

# ── Check 4: Restore archive ───────────────────────────────────────────────

restore_archive() {
    local archive_name="$1"
    local archive_path="$ARCHIVE_DIR/$archive_name"

    echo "Check: Restore archive"

    if [[ -z "$archive_name" ]]; then
        log_fail "No archive specified. Use: --restore <archive-name>.tar.gz"
        return 1
    fi

    if [[ ! -f "$archive_path" ]]; then
        log_fail "Archive not found: $archive_path"
        log_info "Use --list to see available archives"
        return 1
    fi

    if [[ ! -d "$SESSION_DIR" ]]; then
        log_verbose "Creating session directory: $SESSION_DIR"
        mkdir -p "$SESSION_DIR"
    fi

    log_verbose "Restoring archive: $archive_name"
    if tar -xzf "$archive_path" -C "$SESSION_DIR" 2>/dev/null; then
        local restored_count
        restored_count=$(tar -tzf "$archive_path" 2>/dev/null | wc -l | tr -d ' ')
        log_pass "Restored $restored_count file(s) from $archive_name to $SESSION_DIR"
        return 0
    else
        log_fail "Failed to restore archive: $archive_name"
        return 1
    fi
}

# ── Check 5: List archives ─────────────────────────────────────────────────

list_archives() {
    echo "Check: List available archives"

    if [[ ! -d "$ARCHIVE_DIR" ]]; then
        log_info "No archived-sessions/ directory found — no archives exist yet"
        return 0
    fi

    local archives=()
    while IFS= read -r -d '' f; do
        archives+=("$f")
    done < <(find "$ARCHIVE_DIR" -maxdepth 1 -name 'sessions-archive-*.tar.gz' -print0 2>/dev/null | sort -z)

    if [[ ${#archives[@]} -eq 0 ]]; then
        log_info "No archives found in $ARCHIVE_DIR"
        return 0
    fi

    echo "  Found ${#archives[@]} archive(s) in $ARCHIVE_DIR:"
    echo ""
    for f in "${archives[@]}"; do
        local fname
        fname="$(basename "$f")"
        local fsize
        fsize=$(wc -c < "$f" | tr -d ' ')
        local fcount
        fcount=$(tar -tzf "$f" 2>/dev/null | wc -l | tr -d ' ')
        local fdate
        if stat -f '%Sm' "$f" >/dev/null 2>&1; then
            fdate=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$f" 2>/dev/null)
        else
            fdate=$(stat -c '%y' "$f" 2>/dev/null | cut -d'.' -f1)
        fi
        printf "  %-45s %8s bytes  %3d files  (%s)\n" "$fname" "$fsize" "$fcount" "$fdate"
    done
    echo ""

    # Calculate total size and file count
    local total_size=0
    local total_files=0
    for f in "${archives[@]}"; do
        local sz
        sz=$(wc -c < "$f" | tr -d ' ')
        total_size=$((total_size + sz))
        local fc
        fc=$(tar -tzf "$f" 2>/dev/null | wc -l | tr -d ' ')
        total_files=$((total_files + fc))
    done
    echo "  Total: ${#archives[@]} archive(s), $total_files file(s), $total_size bytes"

    log_pass "Archive listing complete"
    return 0
}

# ── Print Summary ──────────────────────────────────────────────────────────

print_summary() {
    echo ""
    echo "=========================================="
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${BLUE}DRY RUN — no files were modified.${NC}"
    fi
    if [[ "$EXIT_CODE" -eq 0 ]]; then
        echo -e "${GREEN}Session archive completed successfully.${NC}"
    else
        echo -e "${RED}Session archive completed with errors.${NC}"
    fi
    echo "=========================================="
}

# ── Main ───────────────────────────────────────────────────────────────────

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help)
            usage
            ;;
        --days)
            if [[ -z "$2" || ! "$2" =~ ^[0-9]+$ ]]; then
                echo "Error: --days requires a positive integer argument"
                exit 1
            fi
            DAYS_OLD="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --restore)
            if [[ -z "$2" ]]; then
                echo "Error: --restore requires an archive filename"
                exit 1
            fi
            RESTORE_ARCHIVE="$2"
            shift 2
            ;;
        --list)
            LIST_ONLY=true
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage info."
            exit 1
            ;;
    esac
done

echo "=== Session Archiver — Workflow State Engine ==="
echo "Project root: $PROJECT_ROOT"
echo "Days old: $DAYS_OLD, dry-run: $DRY_RUN, verbose: $VERBOSE"
echo ""

# Route: --list
if [[ "$LIST_ONLY" == true ]]; then
    list_archives
    exit "$EXIT_CODE"
fi

# Route: --restore
if [[ -n "$RESTORE_ARCHIVE" ]]; then
    restore_archive "$RESTORE_ARCHIVE"
    print_summary
    exit "$EXIT_CODE"
fi

# Route: archive
check_session_dir || exit "$EXIT_CODE"
echo ""
find_old_sessions || {
    if [[ "$EXIT_CODE" -eq 0 ]]; then
        # No old sessions found is not an error
        echo ""
        log_info "Nothing to archive — exiting."
        exit 0
    fi
    exit "$EXIT_CODE"
}
echo ""
create_archive
echo ""
print_summary
exit "$EXIT_CODE"