#!/usr/bin/env bash
# =============================================================================
# detect-parallel-conflicts.sh — Detect file conflicts between parallel agents
#
# file modifications. Used by the orchestrator to reconcile parallel
# agent outputs before accepting changes.
#
# Usage:
#   ./scripts/detect-parallel-conflicts.sh --agent1 FILELIST1 --agent2 FILELIST2
#   ./scripts/detect-parallel-conflicts.sh --diff1 agent1.diff --diff2 agent2.diff
#   ./scripts/detect-parallel-conflicts.sh --agent1 F1 --agent2 F2 --verbose
#
# Input format: One file path per line (or a unified diff — script auto-detects)
#
# Exit codes:
#   0 = No conflicts
#   1 = Conflicts found
#   2 = Usage error
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERBOSE=false

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
AGENT1_FILE=""
AGENT2_FILE=""
AGENT1_LABEL="agent-1"
AGENT2_LABEL="agent-2"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# JSON merge config
JSON_MERGE=false
BASE_FILE=""
FILE1=""
FILE2=""
LABEL1="agent-1"
LABEL2="agent-2"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Detect file conflicts between two parallel agents.

Modes:
  file-level (default):
    --agent1 FILE    File list from first agent (one path per line, or diff)
    --agent2 FILE    File list from second agent
    --label1 TEXT     Label for agent 1 (default: "agent-1")
    --label2 TEXT     Label for agent 2 (default: "agent-2")

  json-merge (semantic JSON key-level diff):
    --json-merge      Enable semantic JSON merge conflict detection
    --base FILE       Original (base) contract.json before agent modifications
    --file1 FILE      Contract.json modified by agent 1
    --file2 FILE      Contract.json modified by agent 2
    --label1 TEXT     Label for agent 1
    --label2 TEXT     Label for agent 2

Common:
    --verbose         Show detailed output
    --help            Show this message

Input formats (auto-detected for file-level):
  - Plain file list (one path per line)
  - Unified diff (parses +++ lines)
  - File path list output

Exit codes:
  0 = No conflicts
  1 = Conflicts found
  2 = Usage error
EOF
    exit 0
}

# log_pass/log_fail/log_warn come from scripts/lib. log_info and log_verbose
# stay local: CYAN [INFO] here (lib uses YELLOW) and plain indented verbose
# text (lib tags [VERB]).
log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
log_verbose() { [[ "$VERBOSE" == true ]] && echo "  $1"; }

# --- Parse diff or plain file list -----------------------------------------
extract_files() {
    local input="$1"
    local output
    output=$(mktemp)

    # Check if it looks like a unified diff (contains +++ lines)
    if grep -q '^+++ ' "$input" 2>/dev/null; then
        # Extract files from diff — look for +++ b/ paths
        grep '^+++ ' "$input" | sed 's/^+++ b\///' | sed 's/^+++ //' | sort -u > "$output"
    elif grep -q '^diff ' "$input" 2>/dev/null; then
        # Another diff format
        grep '^--- ' "$input" | sed 's/^--- a\///' | sort -u > "$output"
    else
        # Plain file list
        grep -v '^$' "$input" | grep -v '^#' | sed 's|^\./||' | sort -u > "$output"
    fi

    echo "$output"
}

# --- Semantic JSON merge conflict detection ---------------------------------
# Walks two JSON files against a base, identifies conflicts (both agents changed
# the same key) vs safe merges (only one agent changed a key).
json_merge_diff() {
    local base="$1"
    local file1="$2"
    local file2="$3"
    local label1="$4"
    local label2="$5"

    if [[ ! -f "$base" ]]; then log_fail "Base file not found: $base"; return 1; fi
    if [[ ! -f "$file1" ]]; then log_fail "File 1 not found: $file1"; return 1; fi
    if [[ ! -f "$file2" ]]; then log_fail "File 2 not found: $file2"; return 1; fi

    if ! command -v jq >/dev/null 2>&1; then
        log_fail "jq is required for json-merge mode"
        return 1
    fi

    echo "=========================================="
    echo " JSON Merge Conflict Detection"
    echo " Base:  $(basename "$base")"
    echo " Agent: $label1 ($(basename "$file1"))"
    echo " Agent: $label2 ($(basename "$file2"))"
    echo "=========================================="
    echo ""

    # Extract all top-level keys from all three files
    local base_keys=$(jq -r 'keys[]' "$base" 2>/dev/null | sort)
    local f1_keys=$(jq -r 'keys[]' "$file1" 2>/dev/null | sort)
    local f2_keys=$(jq -r 'keys[]' "$file2" 2>/dev/null | sort)

    local all_keys=$(echo -e "$base_keys\n$f1_keys\n$f2_keys" | sort -u)

    local conflicts=()
    local safe_merges=()
    local additions=()

    for key in $all_keys; do
        local base_val
        local f1_val
        local f2_val
        base_val=$(jq -r "if .[\"$key\"] then .[\"$key\"] else \"__NULL__\" end" "$base" 2>/dev/null || echo "__NULL__")
        f1_val=$(jq -r "if .[\"$key\"] then .[\"$key\"] else \"__NULL__\" end" "$file1" 2>/dev/null || echo "__NULL__")
        f2_val=$(jq -r "if .[\"$key\"] then .[\"$key\"] else \"__NULL__\" end" "$file2" 2>/dev/null || echo "__NULL__")

        local in_base=false; [[ "$base_val" != "__NULL__" ]] && in_base=true
        local in_f1=false;   [[ "$f1_val" != "__NULL__" ]] && in_f1=true
        local in_f2=false;   [[ "$f2_val" != "__NULL__" ]] && in_f2=true

        if $in_base && $in_f1 && $in_f2; then
            # Key exists in all three — check for divergence
            if [[ "$f1_val" != "$base_val" && "$f2_val" != "$base_val" && "$f1_val" != "$f2_val" ]]; then
                conflicts+=("{\"key\":\"$key\",\"base\":$base_val,\"$label1\":$f1_val,\"$label2\":$f2_val}")
            elif [[ "$f1_val" != "$base_val" ]]; then
                safe_merges+=("{\"key\":\"$key\",\"changed_by\":\"$label1\",\"base\":$base_val,\"value\":$f1_val}")
            elif [[ "$f2_val" != "$base_val" ]]; then
                safe_merges+=("{\"key\":\"$key\",\"changed_by\":\"$label2\",\"base\":$base_val,\"value\":$f2_val}")
            fi
        elif ! $in_base && $in_f1 && ! $in_f2; then
            additions+=("{\"key\":\"$key\",\"added_by\":\"$label1\",\"value\":$f1_val}")
        elif ! $in_base && ! $in_f1 && $in_f2; then
            additions+=("{\"key\":\"$key\",\"added_by\":\"$label2\",\"value\":$f2_val}")
        elif ! $in_base && $in_f1 && $in_f2; then
            # Both agents added the same key — check if values match
            if [[ "$f1_val" == "$f2_val" ]]; then
                safe_merges+=("{\"key\":\"$key\",\"changed_by\":\"both\",\"value\":$f1_val}")
            else
                conflicts+=("{\"key\":\"$key\",\"added_by_both\":true,\"$label1\":$f1_val,\"$label2\":$f2_val}")
            fi
        fi
    done

    # Report
    local has_issues=false

    if [[ ${#conflicts[@]} -gt 0 ]]; then
        has_issues=true
        log_fail "${#conflicts[@]} semantic conflict(s) detected!"
        echo ""
        for entry in "${conflicts[@]}"; do
            local key=$(echo "$entry" | jq -r '.key')
            echo "  ⚠  Key: $key"
            echo "      Base:  $(echo "$entry" | jq -c '.base // "__missing__"')"
            echo "      $label1: $(echo "$entry" | jq -c ".[\"$label1\"] // .added_by_both // .value // \"__missing__\"")"
            echo "      $label2: $(echo "$entry" | jq -c ".[\"$label2\"] // .added_by_both // .value // \"__missing__\"")"
            echo ""
        done
    fi

    if [[ ${#safe_merges[@]} -gt 0 ]]; then
        log_info "${#safe_merges[@]} safe merge(s) — only one agent modified the key"
        if [[ "$VERBOSE" == true ]]; then
            echo ""
            for entry in "${safe_merges[@]}"; do
                local key=$(echo "$entry" | jq -r '.key')
                local changed_by=$(echo "$entry" | jq -r '.changed_by')
                echo "  ✓ Key: $key (changed by: $changed_by)"
            done
            echo ""
        fi
    fi

    if [[ ${#additions[@]} -gt 0 ]]; then
        log_info "${#additions[@]} key addition(s) — no conflict"
        if [[ "$VERBOSE" == true ]]; then
            echo ""
            for entry in "${additions[@]}"; do
                local key=$(echo "$entry" | jq -r '.key')
                local added_by=$(echo "$entry" | jq -r '.added_by')
                echo "  + Key: $key (added by: $added_by)"
            done
            echo ""
        fi
    fi

    if ! $has_issues; then
        log_pass "No semantic conflicts — all JSON changes can be auto-merged"
    else
        log_warn "Resolve conflicts manually or re-delegate conflicting keys serially"
    fi

    return $( [[ "$has_issues" == false ]] && echo 0 || echo 1 )
}

# --- Main ------------------------------------------------------------------
main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --agent1) AGENT1_FILE="$2"; shift 2 ;;
            --agent2) AGENT2_FILE="$2"; shift 2 ;;
            --diff1) AGENT1_FILE="$2"; shift 2 ;;
            --diff2) AGENT2_FILE="$2"; shift 2 ;;
            --label1) AGENT1_LABEL="$2"; LABEL1="$2"; shift 2 ;;
            --label2) AGENT2_LABEL="$2"; LABEL2="$2"; shift 2 ;;
            --json-merge) JSON_MERGE=true; shift ;;
            --base) BASE_FILE="$2"; shift 2 ;;
            --file1) FILE1="$2"; shift 2 ;;
            --file2) FILE2="$2"; shift 2 ;;
            --verbose) VERBOSE=true; shift ;;
            --help|-h) usage ;;
            *) echo "Unknown option: $1"; usage ;;
        esac
    done

    # Route to json-merge mode
    if [[ "$JSON_MERGE" == true ]]; then
        if [[ -z "$BASE_FILE" || -z "$FILE1" || -z "$FILE2" ]]; then
            echo "ERROR: --json-merge requires --base, --file1, and --file2" >&2
            exit 2
        fi
        json_merge_diff "$BASE_FILE" "$FILE1" "$FILE2" "$LABEL1" "$LABEL2"
        exit $?
    fi

    if [[ -z "$AGENT1_FILE" || -z "$AGENT2_FILE" ]]; then
        echo "ERROR: --agent1 and --agent2 are required" >&2
        exit 2
    fi

    if [[ ! -f "$AGENT1_FILE" ]]; then
        echo "ERROR: File not found: $AGENT1_FILE" >&2
        exit 2
    fi
    if [[ ! -f "$AGENT2_FILE" ]]; then
        echo "ERROR: File not found: $AGENT2_FILE" >&2
        exit 2
    fi

    echo "=========================================="
    echo " Parallel Conflict Detection Report"
    echo " Agent 1: $AGENT1_LABEL ($AGENT1_FILE)"
    echo " Agent 2: $AGENT2_LABEL ($AGENT2_FILE)"
    echo "=========================================="
    echo ""

    # Extract file lists
    local files1 files2
    files1=$(extract_files "$AGENT1_FILE")
    files2=$(extract_files "$AGENT2_FILE")

    local count1 count2
    count1=$(wc -l < "$files1" | tr -d ' ')
    count2=$(wc -l < "$files2" | tr -d ' ')

    log_info "Agent 1 modifies $count1 file(s)"
    log_info "Agent 2 modifies $count2 file(s)"

    if [[ "$VERBOSE" == true ]]; then
        echo ""
        log_verbose "=== $AGENT1_LABEL files ==="
        while IFS= read -r f; do log_verbose "  $f"; done < "$files1"
        echo ""
        log_verbose "=== $AGENT2_LABEL files ==="
        while IFS= read -r f; do log_verbose "  $f"; done < "$files2"
        echo ""
    fi

    # Find conflicts
    local conflicts
    conflicts=$(comm -12 "$files1" "$files2" | grep -v '^$' || true)

    local conflict_count
    if [[ -z "$conflicts" ]]; then
        conflict_count=0
    else
        conflict_count=$(echo "$conflicts" | wc -l | tr -d ' ')
    fi

    echo ""
    if [[ "$conflict_count" -eq 0 ]]; then
        log_pass "No conflicts — agents modified disjoint file sets"
        rm -f "$files1" "$files2"
        exit 0
    else
        log_fail "$conflict_count overlapping file(s) detected!"
        echo ""
        echo "$conflicts" | while IFS= read -r f; do
            echo "  ⚠  $f"
        done
        echo ""
        log_info "Resolution: Re-deploy these files serially (one agent at a time)"
        rm -f "$files1" "$files2"
        exit 1
    fi
}

main "$@"
