#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# check-cross-references.sh — Cross-reference integrity checker
#
# Implements doc/health-check.md lens 4 ("Agent Doc References"):
# every path, skill, agent, and script named inside engine/ docs and config
# must resolve to a real file on disk. All checks are mechanical
# (grep + filesystem), no LLM involved.
#
# Checks:
#   1. Markdown relative links    [text](target) in engine/**/*.md
#   2. Absolute engine refs       /opt/engine/<path> in *.md *.json *.sh *.template
#   3. Skill self-invocation IDs  /skill <id> mentions + frontmatter name vs dir
#   4. Script refs                scripts/<name>.sh mentions in *.md *.json
#   5. Agent refs                 agents/<name>.md mentions in *.md *.json
#   6. Doc/usage/commands/contract/rules path mentions in *.md *.json
#
# Usage:
#   ./scripts/check-cross-references.sh          # Run all checks
#   ./scripts/check-cross-references.sh --help   # Show usage
#   ./scripts/check-cross-references.sh --verbose  # Detailed output
#   ./scripts/check-cross-references.sh --strict   # Fail on first violation
#   ./scripts/check-cross-references.sh --check NAME  # Run a single check by name
#
# Exit codes:
#   0 — All references resolve
#   1 — One or more broken references found
#
# Requirements:
#   - bash 4+
#   - GNU grep (PCRE via -oP)
#
# This script is idempotent — safe to run multiple times.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Config ──────────────────────────────────────────────────────────────────
VERBOSE=false
STRICT=false
ONLY_CHECK=""
EXIT_CODE=0
VIOLATIONS=0
CHECK_COUNT=0
PASS_COUNT=0
FAIL_COUNT=0
BROKEN_TOTAL=0

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
check-cross-references.sh — Cross-reference integrity checker

SYNOPSIS
    ./scripts/check-cross-references.sh [OPTIONS]

OPTIONS
    --help       Show this help message and exit
    --verbose    Print detailed output for each check
    --strict     Exit immediately on first violation
    --check NAME Run a single check by name; an unknown name prints this
                 usage and exits 2. Valid names:
                 markdown-links, engine-refs, skill-ids, script-refs,
                 agent-refs, relpath-refs, context-standards, access-policy

CHECKS
  1. Markdown relative links
     Extracts [text](target) from engine/**/*.md; skips http(s)/mailto and
     anchor-only targets; strips #anchor; resolves relative to the source
     file's directory. /opt/engine/... targets are mapped to engine/ root.

  2. Absolute engine refs
     Extracts /opt/engine/<path> from *.md *.json *.sh *.template; flags
     MISSING when engine/<path> does not exist.

  3. Skill self-invocation IDs
     For each skills/*/SKILL.md: flags WRONG-ID when a standalone /skill <id>
     mention has no matching skills/<id>/ directory; flags
     FRONTMATTER-MISMATCH when the frontmatter name: differs from the
     directory name.

  4. Script refs
     Extracts standalone scripts/<name>.sh mentions from *.md *.json
     (substrings inside longer paths or URLs are ignored); flags MISSING
     when scripts/<name>.sh does not exist.

  5. Agent refs
     Extracts standalone agents/<name>.md mentions from *.md *.json
     (substrings inside longer paths or URLs are ignored); flags MISSING
     when agents/<name>.md does not exist.

  6. Doc/usage/commands/contract/rules refs
     Extracts standalone doc/, usage/, commands/, contract/, rules/ path
     mentions from *.md *.json (excluding skills/<name>/{references,
     reference,library,templates,scripts,evals}/ subdirs); flags MISSING
     when engine/<path> does not exist.

  7. Context-standards wiring
     Verifies skills/context-standards/SKILL.md exists and that
     agents/developer.md plus agents/quality-analyst.md reference it.
     agent.md mentions are informational only (never fail the gate).

  8. lean-ctx access policy
     Verifies every agents/*.md carries the identical "Access policy"
     line (plus a lean-ctx reference) and that agent.md declares the
     mandatory access layer.

EXIT CODES
  0   All references resolve
  1   One or more broken references found

EXAMPLES
    ./scripts/check-cross-references.sh
    ./scripts/check-cross-references.sh --verbose
    ./scripts/check-cross-references.sh --strict
    ./scripts/check-cross-references.sh --check script-refs
USAGE
    exit "${1:-0}"
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

# Trim trailing sentence punctuation that grep absorbs into paths
trim_path() {
    local p="$1"
    p="${p%.}"
    p="${p%/}"
    echo "$p"
}

# ── Check 1: Markdown relative links ────────────────────────────────────────
check_markdown_links() {
    echo "---"
    echo "Check 1: Markdown relative links"
    echo "  Verifying [text](target) links in engine/**/*.md resolve on disk"

    local broken=0 checked=0
    local f target targets resolved rel

    while IFS= read -r f; do
        rel="${f#"$PROJECT_ROOT"/}"
        targets=$(grep -oE '\]\([^)]+\)' "$f" 2>/dev/null | sed -e 's/^](//' -e 's/)$//' || true)
        while IFS= read -r target; do
            [[ -z "$target" ]] && continue
            target="${target%%#*}"                # strip #anchor
            [[ -z "$target" ]] && continue        # anchor-only link
            target="$(trim_path "$target")"
            [[ -z "$target" ]] && continue
            case "$target" in
                http://*|https://*|mailto:*) continue ;;
            esac
            case "$target" in
                /opt/engine/*) resolved="$PROJECT_ROOT/${target#/opt/engine/}" ;;
                /*) resolved="$target" ;;
                *) resolved="$(dirname "$f")/$target" ;;
            esac
            checked=$((checked + 1))
            if [[ ! -e "$resolved" ]]; then
                broken=$((broken + 1))
                BROKEN_TOTAL=$((BROKEN_TOTAL + 1))
                log_fail "BROKEN $rel -> '$target'"
                log_verbose "resolved to: $resolved"
            else
                log_verbose "$rel -> '$target' OK"
            fi
        done <<< "$targets"
    done < <(find "$PROJECT_ROOT" -type f -name '*.md' | sort)

    if [[ "$broken" -eq 0 ]]; then
        log_pass "Check 1: all $checked markdown links resolve"
    else
        log_verbose "Check 1: $broken broken of $checked checked"
    fi
}

# ── Check 2: Absolute engine refs (/opt/engine/<path>) ─────────────────────
check_engine_absolute_refs() {
    echo "---"
    echo "Check 2: Absolute engine refs"
    echo "  Verifying /opt/engine/<path> mentions map to engine/<path>"

    local broken=0 checked=0
    local p files

    files=$(find "$PROJECT_ROOT" -type f \( -name '*.md' -o -name '*.json' -o -name '*.sh' -o -name '*.template' \) | sort)

    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        p="$(trim_path "$p")"
        [[ -z "$p" || "$p" == "/opt/engine" ]] && continue
        local rel_path="${p#/opt/engine/}"
        checked=$((checked + 1))
        if [[ ! -e "$PROJECT_ROOT/$rel_path" ]]; then
            broken=$((broken + 1))
            BROKEN_TOTAL=$((BROKEN_TOTAL + 1))
            log_fail "MISSING /opt/engine/$rel_path (engine/$rel_path does not exist)"
        else
            log_verbose "/opt/engine/$rel_path OK"
        fi
    done < <(echo "$files" | xargs grep -hoE '/opt/engine/[A-Za-z0-9_./-]+' 2>/dev/null | sort -u || true)

    if [[ "$broken" -eq 0 ]]; then
        log_pass "Check 2: all $checked /opt/engine refs resolve"
    else
        log_verbose "Check 2: $broken missing of $checked checked"
    fi
}

# ── Check 3: Skill self-invocation IDs ─────────────────────────────────────
check_skill_ids() {
    echo "---"
    echo "Check 3: Skill self-invocation IDs"
    echo "  Verifying /skill <id> mentions and frontmatter names in skills/*/SKILL.md"

    local broken=0 checked=0
    local skill_dir name skill_md fm_name id ids

    while IFS= read -r skill_dir; do
        name="$(basename "$skill_dir")"
        skill_md="$skill_dir/SKILL.md"
        [[ -f "$skill_md" ]] || continue

        # Frontmatter name vs directory name
        fm_name="$(awk 'NR==1 && $0=="---" {infm=1; next} infm && $0=="---" {exit} infm && /^name:/{sub(/^name:[ ]*/,""); print; exit}' "$skill_md" 2>/dev/null || true)"
        checked=$((checked + 1))
        if [[ -n "$fm_name" && "$fm_name" != "$name" ]]; then
            broken=$((broken + 1))
            BROKEN_TOTAL=$((BROKEN_TOTAL + 1))
            log_fail "FRONTMATTER-MISMATCH skills/$name: frontmatter name '$fm_name' != directory '$name'"
        fi

        # /skill <id> mentions must point at existing skill dirs
        ids=$(grep -oP '(?<![A-Za-z0-9_-])/skill[[:space:]]+[a-z0-9][a-z0-9._-]*' "$skill_md" 2>/dev/null | awk '{print $2}' | sort -u || true)
        while IFS= read -r id; do
            [[ -z "$id" ]] && continue
            checked=$((checked + 1))
            if [[ ! -d "$PROJECT_ROOT/skills/$id" ]]; then
                broken=$((broken + 1))
                BROKEN_TOTAL=$((BROKEN_TOTAL + 1))
                log_fail "WRONG-ID skills/$name: /skill $id (no skills/$id/ directory)"
            else
                log_verbose "skills/$name -> /skill $id OK"
            fi
        done <<< "$ids"
    done < <(find "$PROJECT_ROOT/skills" -maxdepth 1 -mindepth 1 -type d | sort)

    if [[ "$broken" -eq 0 ]]; then
        log_pass "Check 3: all $checked skill IDs and frontmatter names consistent"
    else
        log_verbose "Check 3: $broken problems of $checked checked"
    fi
}

# ── Check 4: Script refs (scripts/<name>.sh) ───────────────────────────────
check_script_refs() {
    echo "---"
    echo "Check 4: Script refs"
    echo "  Verifying scripts/<name>.sh mentions resolve to real scripts"

    local broken=0 checked=0
    local s

    while IFS= read -r s; do
        [[ -z "$s" ]] && continue
        checked=$((checked + 1))
        if [[ ! -f "$PROJECT_ROOT/$s" ]]; then
            broken=$((broken + 1))
            BROKEN_TOTAL=$((BROKEN_TOTAL + 1))
            log_fail "MISSING $s"
        else
            log_verbose "$s OK"
        fi
    done < <(find "$PROJECT_ROOT" -type f \( -name '*.md' -o -name '*.json' \) -print0 2>/dev/null \
        | xargs -0 grep -hoP '(?<![A-Za-z0-9_./-])\Kscripts/[A-Za-z0-9_.-]+\.sh' 2>/dev/null \
        | sort -u || true)

    if [[ "$broken" -eq 0 ]]; then
        log_pass "Check 4: all $checked script refs resolve"
    else
        log_verbose "Check 4: $broken missing of $checked checked"
    fi
}

# ── Check 5: Agent refs (agents/<name>.md) ─────────────────────────────────
check_agent_refs() {
    echo "---"
    echo "Check 5: Agent refs"
    echo "  Verifying agents/<name>.md mentions resolve to real agent files"

    local broken=0 checked=0
    local a

    while IFS= read -r a; do
        [[ -z "$a" ]] && continue
        checked=$((checked + 1))
        if [[ ! -f "$PROJECT_ROOT/$a" ]]; then
            broken=$((broken + 1))
            BROKEN_TOTAL=$((BROKEN_TOTAL + 1))
            log_fail "MISSING $a"
        else
            log_verbose "$a OK"
        fi
    done < <(find "$PROJECT_ROOT" -type f \( -name '*.md' -o -name '*.json' \) -print0 2>/dev/null \
        | xargs -0 grep -hoP '(?<![A-Za-z0-9_./-])\Kagents/[A-Za-z0-9_.-]+\.md' 2>/dev/null \
        | sort -u || true)

    if [[ "$broken" -eq 0 ]]; then
        log_pass "Check 5: all $checked agent refs resolve"
    else
        log_verbose "Check 5: $broken missing of $checked checked"
    fi
}

# ── Check 6: Doc/usage/commands/contract/rules path mentions ───────────────
check_relpath_refs() {
    echo "---"
    echo "Check 6: Doc/usage/commands/contract/rules refs"
    echo "  Verifying relative path mentions resolve under engine/"
    echo "  (excluding skills/<name>/{references,reference,library,templates,scripts,evals}/)"

    local broken=0 checked=0
    local p

    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        p="$(trim_path "$p")"
        [[ -z "$p" ]] && continue
        checked=$((checked + 1))
        local resolved="$PROJECT_ROOT/$p"
        # Engine-relative first; fall back to any matching path suffix so
        # skill-local targets (e.g. skills/firecrawl/rules/install.md) resolve.
        if [[ ! -e "$resolved" ]]; then
            resolved="$(find "$PROJECT_ROOT" -type f -path "*/$p" -print -quit 2>/dev/null || true)"
        fi
        if [[ -z "$resolved" || ! -e "$resolved" ]]; then
            broken=$((broken + 1))
            BROKEN_TOTAL=$((BROKEN_TOTAL + 1))
            log_fail "MISSING $p"
        else
            log_verbose "$p OK ($resolved)"
        fi
    done < <(find "$PROJECT_ROOT" -type f \( -name '*.md' -o -name '*.json' \) 2>/dev/null \
        | grep -vE "skills/[^/]+/(references|reference|library|templates|scripts|evals)/" \
        | xargs grep -hoP '(?<![A-Za-z0-9_./-])\K(doc|usage|commands|contract|rules)/[A-Za-z0-9_./-]+' 2>/dev/null \
        | sort -u || true)

    if [[ "$broken" -eq 0 ]]; then
        log_pass "Check 6: all $checked relative path refs resolve"
    else
        log_verbose "Check 6: $broken missing of $checked checked"
    fi
}

# ── Check 7: Context-standards wiring ──────────────────────────────────────
check_context_standards_wiring() {
    echo "---"
    echo "Check 7: Context-standards wiring"
    echo "  Verifying skills/context-standards exists and agent instructions reference it"

    local broken=0
    local skill_md="$PROJECT_ROOT/skills/context-standards/SKILL.md"
    local executor_md="$PROJECT_ROOT/agents/developer.md"
    local reviewer_md="$PROJECT_ROOT/agents/quality-analyst.md"

    if [[ ! -f "$skill_md" ]]; then
        broken=$((broken + 1))
        BROKEN_TOTAL=$((BROKEN_TOTAL + 1))
        log_fail "MISSING skills/context-standards/SKILL.md"
    else
        log_verbose "skills/context-standards/SKILL.md OK"
    fi

    local f
    for f in "$executor_md" "$reviewer_md"; do
        if [[ ! -f "$f" ]] || ! grep -q 'context-standards' "$f" 2>/dev/null; then
            broken=$((broken + 1))
            BROKEN_TOTAL=$((BROKEN_TOTAL + 1))
            log_fail "MISSING context-standards reference in agents/$(basename "$f")"
        else
            log_verbose "agents/$(basename "$f") references context-standards"
        fi
    done

    # Orchestrator doc (agent.md): informational only, never fails the gate
    if grep -q 'context-standards' "$PROJECT_ROOT/agent.md" 2>/dev/null; then
        log_verbose "agent.md references context-standards (informational)"
    else
        log_info "agent.md does not reference context-standards (informational only)"
    fi

    if [[ "$broken" -eq 0 ]]; then
        log_pass "Check 7: context-standards skill present and wired"
    else
        log_verbose "Check 7: $broken wiring problem(s)"
    fi
}

# ── Check 8: lean-ctx access policy ─────────────────────────────────────────
# Every agent instruction file must route tool access through lean-ctx: each
# carries the identical "Access policy" line, and agent.md declares the
# mandatory access layer.
check_access_policy() {
    echo "Check 8: lean-ctx access policy"
    echo "  Verifying agents/*.md carry the Access policy line and agent.md declares the access layer"

    local broken=0
    local f base
    for f in "$PROJECT_ROOT"/agents/*.md; do
        base="$(basename "$f")"
        if [[ ! -f "$f" ]]; then
            broken=$((broken + 1))
            BROKEN_TOTAL=$((BROKEN_TOTAL + 1))
            log_fail "MISSING agents/$base"
            continue
        fi
        if ! grep -q 'lean-ctx' "$f" 2>/dev/null; then
            broken=$((broken + 1))
            BROKEN_TOTAL=$((BROKEN_TOTAL + 1))
            log_fail "agents/$base has no lean-ctx reference"
        elif ! grep -q 'Access policy' "$f" 2>/dev/null; then
            broken=$((broken + 1))
            BROKEN_TOTAL=$((BROKEN_TOTAL + 1))
            log_fail "agents/$base is missing the Access policy line"
        else
            log_verbose "agents/$base carries the access policy"
        fi
    done

    if ! grep -q 'mandatory access layer' "$PROJECT_ROOT/agent.md" 2>/dev/null; then
        broken=$((broken + 1))
        BROKEN_TOTAL=$((BROKEN_TOTAL + 1))
        log_fail "agent.md does not declare the mandatory access layer"
    else
        log_verbose "agent.md declares the mandatory access layer"
    fi

    if [[ "$broken" -eq 0 ]]; then
        log_pass "Check 8: lean-ctx access policy present in all agents and agent.md"
    else
        log_verbose "Check 8: $broken access-policy problem(s)"
    fi
}

# ── Summary ─────────────────────────────────────────────────────────────────
print_summary() {
    local total_checks=$((CHECK_COUNT + PASS_COUNT + FAIL_COUNT))
    local skills agents scripts commands
    skills=$(find "$PROJECT_ROOT/skills" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    agents=$(find "$PROJECT_ROOT/agents" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
    scripts=$(find "$PROJECT_ROOT/scripts" -maxdepth 1 -name '*.sh' 2>/dev/null | wc -l | tr -d ' ')
    commands=$(find "$PROJECT_ROOT/commands" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')

    echo "---"
    echo "Summary: $total_checks checks run, $BROKEN_TOTAL broken reference(s), $VIOLATIONS violation(s)"
    echo "Info: $skills skills, $agents agents, $scripts scripts, $commands commands"
    if [[ "$VIOLATIONS" -eq 0 ]]; then
        echo -e "${GREEN}All cross-references resolve.${NC}"
    else
        echo -e "${RED}${VIOLATIONS} broken reference(s) found.${NC}"
    fi
}

# ── Main ────────────────────────────────────────────────────────────────────
main() {
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
            --check)
                if [[ -z "${2:-}" ]]; then
                    echo "Error: --check requires a check name."
                    echo "Valid names: markdown-links, engine-refs, skill-ids, script-refs, agent-refs, relpath-refs, context-standards, access-policy"
                    exit 2
                fi
                ONLY_CHECK="$2"
                shift 2
                ;;
            *)
                echo "Unknown option: $1"
                echo "Use --help for usage information."
                exit 1
                ;;
        esac
    done

    echo "=== Cross-Reference Checker — Workflow State Engine (lens 4) ==="
    echo "Project root: $PROJECT_ROOT"
    echo "Mode: verbose=$VERBOSE, strict=$STRICT"
    echo ""

    if [[ -n "$ONLY_CHECK" ]]; then
        case "$ONLY_CHECK" in
            markdown-links)    check_markdown_links ;;
            engine-refs)       check_engine_absolute_refs ;;
            skill-ids)         check_skill_ids ;;
            script-refs)       check_script_refs ;;
            agent-refs)        check_agent_refs ;;
            relpath-refs)      check_relpath_refs ;;
            context-standards) check_context_standards_wiring ;;
            access-policy)     check_access_policy ;;
            *)
                echo "Unknown check: $ONLY_CHECK" >&2
                usage 2
                ;;
        esac
    else
        check_markdown_links
        check_engine_absolute_refs
        check_skill_ids
        check_script_refs
        check_agent_refs
        check_relpath_refs
        check_context_standards_wiring
        check_access_policy
    fi

    echo ""
    print_summary

    exit "$EXIT_CODE"
}

main "$@"
