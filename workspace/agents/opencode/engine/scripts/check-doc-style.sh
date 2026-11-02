#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# check-doc-style.sh — Mechanical doc-style checker (humanizer ship gate)
#
# Makes the agent.md humanizer ship gate (step 10) mechanically checkable:
# shipped user-facing docs must not carry em/en dashes, AI vocabulary, or
# placeholder text. Internal state files (session/state.md, contract JSON,
# code comments) are exempt from the gate by definition.
#
# Noise stripped before matching: YAML frontmatter, fenced code blocks,
# markdown horizontal rules, badge lines (img.shields.io). Inline code spans
# are NOT stripped — a code span containing a flagged word is still reported
# (known false-positive risk; the default targets verify clean).
#
# Checks:
#   1. Em/en dashes              — matches the literal characters anywhere in prose
#   2. AI vocabulary             — conservative list, case-insensitive, word-bounded
#   3. Placeholder text          — TODO / lorem / coming soon
#
# Usage:
#   ./scripts/check-doc-style.sh [FILE...]     # Check files (default targets if none)
#   ./scripts/check-doc-style.sh --help        # Show usage
#   ./scripts/check-doc-style.sh --verbose     # Detailed output
#   ./scripts/check-doc-style.sh --strict      # Fail on first violation
#
# Exit codes:
#   0 — No violations
#   1 — One or more violations found
#
# Requirements:
#   - bash 4+
#   - GNU grep, awk
#
# This script is idempotent — safe to run multiple times.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # engine/
REPO_ROOT="$(cd "$PROJECT_ROOT/.." && pwd)"                       # repo root (opencode/)

# ── Config ──────────────────────────────────────────────────────────────────
VERBOSE=false
STRICT=false
EXIT_CODE=0
VIOLATIONS=0
CHECK_COUNT=0
PASS_COUNT=0
FAIL_COUNT=0

# CHECK 1 — em/en dash characters (edit list here)
DASH_PATTERN='—|–'

# CHECK 2 — AI vocabulary, conservative list (edit list here).
# Matched case-insensitively with word boundaries.
VOCAB_PATTERN='leverage|leveraging|leveraged|robust|seamless|delve|showcase|in conclusion|game-changer|cutting-edge|elevate|unlock'

# CHECK 3 — placeholder text (edit list here)
PLACEHOLDER_PATTERN='TODO|lorem|coming soon'

# Default targets: shipped user-facing docs. Bare README.md resolves against
# the repo root; engine docs resolve against PROJECT_ROOT (engine/).
DEFAULT_TARGETS=("$REPO_ROOT/README.md" "$PROJECT_ROOT/README.md" "$PROJECT_ROOT/contract/README.md")

# Color output (disable if not a terminal)
if [[ -t 1 ]]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[1;33m'
    NC='\033[0m'
else
    GREEN=''
    RED=''
    YELLOW=''
    NC=''
fi

# ── Help ────────────────────────────────────────────────────────────────────
usage() {
    cat <<'USAGE'
check-doc-style.sh — Mechanical doc-style checker (humanizer ship gate)

SYNOPSIS
    ./scripts/check-doc-style.sh [OPTIONS] [FILE...]

OPTIONS
    --help       Show this help message and exit
    --verbose    Print detailed output for each check
    --strict     Exit immediately on first violation

ARGS
    FILE...      Files to check. With no files, the default set is checked:
                 <repo>/README.md, engine/README.md, engine/contract/README.md

CHECKS
  1. Em/en dashes
     Literal — or – characters anywhere in prose. Each occurrence is one
     violation. Hyphens (-) are fine; only typographic dashes count.

  2. AI vocabulary (conservative list, case-insensitive, word-bounded)
     leverage / leveraging / leveraged, robust, seamless, delve, showcase,
     "in conclusion", game-changer, cutting-edge, elevate, unlock.

  3. Placeholders
     TODO, lorem, coming soon.

NOISE STRIPPED BEFORE MATCHING
    YAML frontmatter, fenced code blocks (```), markdown horizontal rules
    (^---*$), badge lines (img.shields.io). Inline code spans are NOT
    stripped — words inside `code spans` are still reported, so identifiers
    or URLs that legitimately contain a flagged word may false-positive.
    The default targets verify clean; keep that true when editing them.

EXIT CODES
  0   No violations
  1   One or more violations found

EXAMPLES
    ./scripts/check-doc-style.sh
    ./scripts/check-doc-style.sh --verbose
    ./scripts/check-doc-style.sh --strict docs/PLAN.md
USAGE
    exit 0
}

# ── Helpers ─────────────────────────────────────────────────────────────────
log_pass() {
    local msg="$1"
    PASS_COUNT=$((PASS_COUNT + 1))
    echo -e "${GREEN}[PASS]${NC} $msg"
}

log_fail() {
    local msg="$1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    VIOLATIONS=$((VIOLATIONS + 1))
    EXIT_CODE=1
    echo -e "${RED}[FAIL]${NC} $msg"
    if [[ "$STRICT" == true ]]; then
        echo "[STRICT] Aborting on first violation."
        exit 1
    fi
}

log_info() {
    local msg="$1"
    CHECK_COUNT=$((CHECK_COUNT + 1))
    if [[ "$VERBOSE" == true ]]; then
        echo -e "${YELLOW}[INFO]${NC} $msg"
    fi
}

log_verbose() {
    local msg="$1"
    if [[ "$VERBOSE" == true ]]; then
        echo "  :: $msg"
    fi
}

# Strip noise and annotate each surviving line with its original line number
# ("FNR:text") so violations report the real file line. Strips, in order:
# YAML frontmatter (first-line --- pair), fenced code blocks (toggle on ```),
# badge lines (img.shields.io), markdown horizontal rules (^---*$).
strip_doc_noise() {
    awk '
        FNR == 1 { infm = 0; infence = 0 }
        FNR == 1 && $0 == "---" { infm = 1; next }
        infm == 1 && $0 == "---" { infm = 0; next }
        infm == 1 { next }
        /^```/ { infence = !infence; next }
        infence == 1 { next }
        /img\.shields\.io/ { next }
        /^---*$/ { next }
        { print FNR ":" $0 }
    ' "$1"
}

# ── Per-file checks ─────────────────────────────────────────────────────────
check_file() {
    local f="$1"
    local rel="${f#"$REPO_ROOT"/}"
    local stream hits hit line word excerpt

    if [[ ! -f "$f" ]]; then
        log_fail "MISSING $rel"
        return
    fi

    stream="$(strip_doc_noise "$f")"

    # CHECK 1: em/en dashes — each occurrence is one violation
    hits="$(grep -nEo "$DASH_PATTERN" <<<"$stream" || true)"
    if [[ -n "$hits" ]]; then
        while IFS= read -r hit; do
            [[ -z "$hit" ]] && continue
            line="${hit%%:*}"
            excerpt="$(sed 's/^[0-9]*://' <<<"$hit" | cut -c1-60)"
            log_fail "DASH $rel:$line: '$excerpt'"
            log_verbose "em/en dash at $rel:$line"
        done <<<"$hits"
    else
        log_verbose "CHECK 1 $rel: no em/en dashes"
    fi

    # CHECK 2: AI vocabulary — each occurrence is one violation
    hits="$(grep -inEo "\b($VOCAB_PATTERN)\b" <<<"$stream" || true)"
    if [[ -n "$hits" ]]; then
        while IFS= read -r hit; do
            [[ -z "$hit" ]] && continue
            line="${hit%%:*}"
            word="$(sed 's/^[0-9]*://' <<<"$hit")"
            log_fail "VOCAB $rel:$line: $word"
        done <<<"$hits"
    else
        log_verbose "CHECK 2 $rel: no AI vocabulary"
    fi

    # CHECK 3: placeholders — each occurrence is one violation
    hits="$(grep -inEo "\b($PLACEHOLDER_PATTERN)\b" <<<"$stream" || true)"
    if [[ -n "$hits" ]]; then
        while IFS= read -r hit; do
            [[ -z "$hit" ]] && continue
            line="${hit%%:*}"
            word="$(sed 's/^[0-9]*://' <<<"$hit")"
            log_fail "PLACEHOLDER $rel:$line: $word"
        done <<<"$hits"
    else
        log_verbose "CHECK 3 $rel: no placeholders"
    fi

    if [[ "$EXIT_CODE" -eq 0 ]]; then
        log_pass "$rel passes doc style gate (dashes/vocabulary/placeholders)"
    fi
}

# ── Summary ─────────────────────────────────────────────────────────────────
print_summary() {
    echo "---"
    echo "Summary: $VIOLATIONS violation(s)"
    if [[ "$VIOLATIONS" -eq 0 ]]; then
        echo -e "${GREEN}All checked docs pass the style gate.${NC}"
    else
        echo -e "${RED}${VIOLATIONS} violation(s) found.${NC}"
        echo "Run \`/skill humanizer\` on the flagged docs (agent.md ship gate step 10)."
    fi
}

# ── Main ────────────────────────────────────────────────────────────────────
main() {
    local targets=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                usage
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            --strict)
                STRICT=true
                shift
                ;;
            --*)
                echo "Unknown option: $1"
                echo "Use --help for usage information."
                exit 1
                ;;
            *)
                targets+=("$1")
                shift
                ;;
        esac
    done

    if [[ ${#targets[@]} -eq 0 ]]; then
        targets=("${DEFAULT_TARGETS[@]}")
    fi

    echo "=== Doc Style Checker — humanizer ship gate (agent.md step 10) ==="
    echo "Repo root: $REPO_ROOT"
    echo "Mode: verbose=$VERBOSE, strict=$STRICT"
    echo ""

    local f
    for f in "${targets[@]}"; do
        check_file "$f"
    done

    echo ""
    print_summary

    exit "$EXIT_CODE"
}

main "$@"
