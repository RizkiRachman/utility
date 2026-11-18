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
JSON_OUT=""
PARALLEL_ELIGIBLE=true
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
    local base="$1" file1="$2" file2="$3" label1="$4" label2="$5"
    local TAB
    TAB=$(printf "\t")
    # Nested scalar-path diff: one jq pass per file emits TSV "path<TAB>value"
    # (value = tojson, so tabs/newlines are escaped and splicing stays valid).
    # v1 limitation: keys containing literal dots make "."-joined paths
    # ambiguous; exact conflict resolution comes with declared rw_sets (C12).
    for f in "$base" "$file1" "$file2"; do
        if [[ ! -f "$f" ]]; then log_fail "File not found: $f"; return 1; fi
    done
    if ! command -v jq >/dev/null 2>&1; then
        log_fail "jq is required for json-merge mode"
        return 1
    fi
    echo "=========================================="
    echo " JSON Merge Conflict Detection (nested scalar paths, depth cap 6)"
    echo " Base:  $(basename "$base")"
    echo " Agent: $label1 ($(basename "$file1"))"
    echo " Agent: $label2 ($(basename "$file2"))"
    echo "=========================================="
    echo ""
    local path_expr=". as \$doc | [paths(scalars)] | .[] | . as \$p | select(length <= 6) | (\$p | map(tostring) | join(\".\")) + \"\t\" + (\$doc | getpath(\$p) | tojson)"
    local tmpm; tmpm=$(mktemp -d)
    jq -r "$path_expr" "$base"  > "$tmpm/base" 2>/dev/null
    jq -r "$path_expr" "$file1" > "$tmpm/f1"   2>/dev/null
    jq -r "$path_expr" "$file2" > "$tmpm/f2"   2>/dev/null
    local all_paths
    all_paths=$(cat "$tmpm/base" "$tmpm/f1" "$tmpm/f2" | cut -f1 | sort -u | grep -v "^$")
    local n_conf=0 n_safe=0 n_add=0
    local conflict_entries=()
    local conflict_paths=()
    local p bv v1 v2 in_b in_1 in_2
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        bv=$(grep -F -m1 -- "${p}${TAB}" "$tmpm/base" | cut -f2 || true); [[ -z "$bv" ]] && bv="__ABSENT__"
        v1=$(grep -F -m1 -- "${p}${TAB}" "$tmpm/f1"   | cut -f2 || true); [[ -z "$v1" ]] && v1="__ABSENT__"
        v2=$(grep -F -m1 -- "${p}${TAB}" "$tmpm/f2"   | cut -f2 || true); [[ -z "$v2" ]] && v2="__ABSENT__"
        in_b=false; in_1=false; in_2=false
        [[ "$bv" != "__ABSENT__" ]] && in_b=true
        [[ "$v1" != "__ABSENT__" ]] && in_1=true
        [[ "$v2" != "__ABSENT__" ]] && in_2=true
        if $in_b && $in_1 && $in_2; then
            if [[ "$v1" != "$bv" && "$v2" != "$bv" && "$v1" != "$v2" ]]; then
                conflict_entries+=("$(jq -n --arg p "$p" --arg l1 "$label1" --arg l2 "$label2" --argjson b "$bv" --argjson a1 "$v1" --argjson a2 "$v2" "{path:\$p, base:\$b, (\$l1):\$a1, (\$l2):\$a2, resolution:\"frozen-first-written\"}")")
                conflict_paths+=("$p")
                n_conf=$((n_conf + 1))
            elif [[ "$v1" != "$bv" || "$v2" != "$bv" ]]; then
                n_safe=$((n_safe + 1))
            fi
        elif ! $in_b && $in_1 && ! $in_2; then
            n_add=$((n_add + 1))
        elif ! $in_b && ! $in_1 && $in_2; then
            n_add=$((n_add + 1))
        elif ! $in_b && $in_1 && $in_2; then
            if [[ "$v1" == "$v2" ]]; then
                n_safe=$((n_safe + 1))
            else
                conflict_entries+=("$(jq -n --arg p "$p" --arg l1 "$label1" --arg l2 "$label2" --argjson a1 "$v1" --argjson a2 "$v2" "{path:\$p, added_by_both:true, (\$l1):\$a1, (\$l2):\$a2, resolution:\"frozen-first-written\"}")")
                conflict_paths+=("$p")
                n_conf=$((n_conf + 1))
            fi
        fi
    done <<< "$all_paths"
    if [[ $n_conf -gt 0 ]]; then
        log_fail "$n_conf semantic conflict(s) detected - FROZEN"
        echo "  FREEZE semantics: first-written value kept at each conflicting path;"
        echo "  re-delegate the conflicting keys SERIALlY, then re-run this check."
        for p in "${conflict_paths[@]}"; do echo "  conflict: $p"; done
        if [[ -n "${JSON_OUT:-}" ]]; then
            printf "%s\n" "${conflict_entries[@]}" | jq -s "{mode:\"json-merge\", conflicts:., resolution:\"frozen\", policy:\"first-written kept; serial re-delegation required\"}" > "$JSON_OUT"
        fi
        rm -rf "$tmpm"
        return 1
    fi
    log_pass "No semantic conflicts - all JSON changes can be auto-merged (${n_safe} safe, ${n_add} additions)"
    if [[ -n "${JSON_OUT:-}" ]]; then
        jq -n "{mode:\"json-merge\", conflicts:[], resolution:\"auto-merge\"}" > "$JSON_OUT"
    fi
    rm -rf "$tmpm"
    return 0
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
            --json-out) JSON_OUT="$2"; shift 2 ;;
            --parallel-eligible) PARALLEL_ELIGIBLE="$2"; shift 2 ;;
            --verbose) VERBOSE=true; shift ;;
            --help|-h) usage ;;
            *) echo "Unknown option: $1"; usage ;;
        esac
    done

    # Route to json-merge mode
    if [[ "$PARALLEL_ELIGIBLE" != "true" ]]; then
        echo "parallel conflict detection: not applicable (scope.parallel_eligible != true)"
        exit 0
    fi
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
