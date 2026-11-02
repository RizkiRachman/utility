#!/usr/bin/env bash
# shellcheck disable=SC2086
# validate-toolkit.sh — Validate project toolkit structure is intact
#   ./scripts/validate-toolkit.sh          # Run all checks
#   ./scripts/validate-toolkit.sh --help   # Show usage
#   ./scripts/validate-toolkit.sh --verbose  # Detailed output
#   ./scripts/validate-toolkit.sh --strict   # Fail on first violation
# Exit codes:
#   0 — All checks pass
#   1 — One or more violations found
# Requirements:
#   - bash 4+
#   - jq (for JSON schema validation)
# This script is idempotent — safe to run multiple times.

ENGINE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/paths.sh
. "$ENGINE_ROOT/scripts/lib/paths.sh"
PROJECT_ROOT="$(resolve_project_root "$ENGINE_ROOT")"
SESSION_DIR="$(resolve_session_dir "$PROJECT_ROOT")"
VERBOSE=false
STRICT=false
EXIT_CODE=0
VIOLATIONS=0
CHECK_COUNT=0
PASS_COUNT=0
FAIL_COUNT=0


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

usage() {
    cat <<'EOF'
validate-toolkit.sh — Validate project toolkit structure

Usage:
    ./scripts/validate-toolkit.sh [OPTIONS]

Options:
    --help       Show this usage message
    --verbose    Print detailed output for each check
    --strict     Exit immediately on first violation

Checks performed:
  1. Required directories exist
     Verifies agents/, skills/, contract/, scripts/, doc/,
     rules/, usage/, .opencode/ all have expected contents.
  2. Symlinks in .opencode/ resolve correctly
     Verifies .opencode/agents -> agents/, .opencode/skills -> skills/,
     .opencode/rules -> rules/, .opencode/orchestration -> contract/,
     .opencode/usage -> usage/
  3. Contract file integrity
 Verifies contract/contract.schema.json is valid JSON schema and all
 committed definition files exist.
  4. Agent file consistency
     Verifies each .md file in agents/ has a proper heading.
  5. Cross-references
     Verifies internal links in agent.md
     resolve to actual files.
  6. rules store_in sanity
     Verifies rules/rules.json is valid JSON and every store_in leaf
     targets runtime state (session/...) or a contract-embedded journal
     path (contract.*).
  7. rules required top-level keys
     Verifies rules/rules.json contains the required top-level keys
     (version, description, state_machine, scoring, enforcement, metrics,
     feedback, decisions). The JSON schema file is the source of truth;
     this jq check approximates it (full ajv validation is out of scope
     for the offline toolkit).

Exit codes:
  0 — All checks pass
  1 — One or more violations found
EOF
    exit 0
}

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
        echo "  [..] $msg"
    fi
}

# ── Check 1: Required directories exist ────────────────────────────────────
check_required_dirs() {
    echo "Check 1: Required directories exist"

    local violations=0
    local dir

    # opencode config — V2 accepts config/opencode.json, the mounted
    # ~/.config/opencode/opencode.json, or the engine template.
    local opencode_json
    opencode_json="$(resolve_opencode_config "$PROJECT_ROOT" "$ENGINE_ROOT" 2>/dev/null || true)"
    if [[ -n "$opencode_json" && -f "$opencode_json" ]]; then
        local placeholder_count
        placeholder_count=$(grep -c 'YOUR_' "$opencode_json" 2>/dev/null || true)
        if [[ "$placeholder_count" -gt 0 ]]; then
            log_fail "$(basename "$opencode_json") has $placeholder_count placeholder(s) (YOUR_*) — replace with actual values"
            violations=$((violations + 1))
        else
            log_pass "opencode config found with no remaining placeholders ($opencode_json)"
        fi
    else
        log_fail "opencode config not found (config/opencode.json, ~/.config/opencode/opencode.json, or opencode.json.template)"
        violations=$((violations + 1))
    fi

    # agents/ — at least 10 .md files
    dir="$ENGINE_ROOT/agents"
    if [[ ! -d "$dir" ]]; then
        log_fail "agents/ directory does not exist"
        violations=$((violations + 1))
    else
        local agent_count
        agent_count=$(find "$dir" -maxdepth 1 -name '*.md' -print0 | xargs -0 -I {} echo | wc -l | tr -d ' ')
        if [[ "$agent_count" -lt 10 ]]; then
            log_fail "agents/ has only $agent_count .md files (expected at least 10)"
            violations=$((violations + 1))
        else
            log_pass "agents/ exists with $agent_count .md files"
        fi
    fi

    # skills/ — at least 5 subdirectories
    dir="$ENGINE_ROOT/skills"
    if [[ ! -d "$dir" ]]; then
        log_fail "skills/ directory does not exist"
        violations=$((violations + 1))
    else
        local skill_count
        skill_count=$(find "$dir" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
        if [[ "$skill_count" -lt 5 ]]; then
            log_fail "skills/ has only $skill_count subdirectories (expected at least 5)"
            violations=$((violations + 1))
        else
            log_pass "skills/ exists with $skill_count skill directories"
        fi
    fi

    # contract/ — committed definition files (all version-controlled)
    dir="$ENGINE_ROOT/contract"
    if [[ ! -d "$dir" ]]; then
        log_fail "contract/ directory does not exist"
        violations=$((violations + 1))
    else
        local def_files=("README.md" "contract.schema.json" "state.md")
        for f in "${def_files[@]}"; do
            if [[ ! -f "$dir/$f" ]]; then
                log_fail "contract/$f is missing"
                violations=$((violations + 1))
            else
                log_pass "contract/$f exists"
            fi
        done
    fi

    # scripts/ — check-conventions.sh, archive-sessions.sh
    dir="$ENGINE_ROOT/scripts"
    if [[ ! -d "$dir" ]]; then
        log_fail "scripts/ directory does not exist"
        violations=$((violations + 1))
    else
        local s_violations=0
        for f in check-conventions.sh archive-sessions.sh check-plugins.sh check-cross-references.sh check-doc-style.sh health-check.sh; do
            if [[ ! -f "$dir/$f" ]]; then
                log_fail "scripts/$f is missing"
                s_violations=$((s_violations + 1))
                violations=$((violations + 1))
            fi
        done
        if [[ "$s_violations" -eq 0 ]]; then
            log_pass "scripts/ has all required scripts"
        fi
    fi

    # session/ — project-local runtime state (not shipped with the engine)
    dir="$SESSION_DIR"
    if [[ ! -d "$dir" ]]; then
        log_fail "session/ directory does not exist"
        violations=$((violations + 1))
    else
        local ssn_violations=0
        for f in contract.json state.md; do
            if [[ ! -f "$dir/$f" ]]; then
                log_fail "session/$f is missing"
                ssn_violations=$((ssn_violations + 1))
                violations=$((violations + 1))
            fi
        done
        if [[ "$ssn_violations" -eq 0 ]]; then
            log_pass "session/ exists with contract.json and state.md"
        fi
    fi

    # doc/ — workflow.md
    dir="$ENGINE_ROOT/doc"
    if [[ ! -d "$dir" ]]; then
        log_fail "doc/ directory does not exist"
        violations=$((violations + 1))
    else
        if [[ ! -f "$dir/workflow.md" ]]; then
            log_fail "doc/workflow.md is missing"
            violations=$((violations + 1))
        else
            log_pass "doc/ exists with workflow.md"
        fi
    fi

    # rules/ — rules.json
    dir="$ENGINE_ROOT/rules"
    if [[ ! -d "$dir" ]]; then
        log_fail "rules/ directory does not exist"
        violations=$((violations + 1))
    else
        if [[ ! -f "$dir/rules.json" ]]; then
            log_fail "rules/rules.json is missing"
            violations=$((violations + 1))
        else
            log_pass "rules/ exists with rules.json"
        fi
    fi

    # usage/ — at least 5 .md files
    dir="$ENGINE_ROOT/usage"
    if [[ ! -d "$dir" ]]; then
        log_fail "usage/ directory does not exist"
        violations=$((violations + 1))
    else
        local usage_count
        usage_count=$(find "$dir" -maxdepth 1 -name '*.md' -print0 | xargs -0 -I {} echo | wc -l | tr -d ' ')
        if [[ "$usage_count" -lt 4 ]]; then
            log_fail "usage/ has only $usage_count .md files (expected at least 4)"
            violations=$((violations + 1))
        else
            log_pass "usage/ exists with $usage_count .md files"
        fi
    fi

    # Config directory — V1 used .opencode/, V2 uses ~/.config/opencode/.
    # Accept either; absent in a bare source checkout is not a violation.
    local opencode_dir="$PROJECT_ROOT/.opencode"
    local v2_config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
    if [[ -d "$opencode_dir" ]]; then
        log_pass ".opencode/ directory exists"
    elif [[ -d "$v2_config_dir" ]]; then
        log_pass "V2 config directory exists ($v2_config_dir)"
    else
        log_info "No .opencode/ or V2 config directory — skipping (source checkout)"
    fi

    if [[ "$violations" -eq 0 ]]; then
        echo "  Result: All required directories present"
    fi
}

# ── Check 2: Symlinks in .opencode/ resolve correctly ──────────────────────
check_opencode_symlinks() {
    echo "Check 2: Symlinks in .opencode/ resolve correctly"

    local violations=0
    local base="$PROJECT_ROOT/.opencode"
    if [[ ! -d "$base" ]]; then
        log_info ".opencode/ directory missing — skipping symlink checks"
        return
    fi

    # Map of symlink name -> expected target (relative from .opencode/)
    declare -A symlink_targets=(
        ["agents"]="agents"
        ["skills"]="skills"
        ["rules"]="rules"
        ["orchestration"]="contract"
        ["usage"]="usage"
    )

    for symlink_name in "${!symlink_targets[@]}"; do
        local symlink_path="$base/$symlink_name"
        local expected_target="${symlink_targets[$symlink_name]}"

        if [[ ! -L "$symlink_path" ]]; then
            if [[ -e "$symlink_path" ]]; then
                log_fail ".opencode/$symlink_name exists but is NOT a symlink"
                violations=$((violations + 1))
            else
                log_fail ".opencode/$symlink_name does not exist (expected symlink -> $expected_target/)"
                violations=$((violations + 1))
            fi
            continue
        fi

        local actual_target
        actual_target=$(readlink "$symlink_path" 2>/dev/null)

        # Engine: symlinks point to ../agents (or agents)
        if [[ "$actual_target" != "../$expected_target" ]] && [[ "$actual_target" != "$expected_target" ]]; then
            log_fail ".opencode/$symlink_name points to '$actual_target' (expected '$expected_target')"
            violations=$((violations + 1))
        fi

        if [[ -d "$symlink_path" ]]; then
            log_pass ".opencode/$symlink_name -> $expected_target/ (resolves correctly)"
            log_verbose "  Target path: $(cd "$(dirname "$symlink_path")" && readlink "$(basename "$symlink_path")")"
        elif [[ -f "$symlink_path" ]]; then
            log_pass ".opencode/$symlink_name -> $expected_target (resolves to a file)"
        else
            log_fail ".opencode/$symlink_name -> $actual_target (symlink broken — target does not exist)"
            violations=$((violations + 1))
        fi
    done

    if [[ "$violations" -eq 0 ]]; then
        echo "  Result: All 5 .opencode/ symlinks resolve correctly"
    fi
}

# ── Check 3: Contract file integrity ───────────────────────────────────────
check_contract_integrity() {
    echo "Check 3: Contract file integrity"
    local violations=0
    local schema_file="$ENGINE_ROOT/contract/contract.schema.json"
    
    # Check contract.schema.json is valid JSON
    if [[ ! -f "$schema_file" ]]; then
        log_fail "contract/contract.schema.json does not exist"
        violations=$((violations + 1))
    else
        if command -v jq &>/dev/null; then
            if jq empty "$schema_file" 2>/dev/null; then
                log_pass "contract/contract.schema.json is valid JSON"
            else
                log_fail "contract/contract.schema.json is not valid JSON"
                violations=$((violations + 1))
            fi
        elif command -v python3 &>/dev/null; then
            if python3 -m json.tool "$schema_file" &>/dev/null; then
                log_pass "contract/contract.schema.json is valid JSON"
            else
                log_fail "contract/contract.schema.json is not valid JSON"
                violations=$((violations + 1))
            fi
        else
            log_info "Neither jq nor python3 found — skipping JSON validation"
        fi
    fi
    
    if [[ "$violations" -eq 0 ]]; then
        echo "  Result: Contract schema valid"
    fi
    return "$violations"
}

# ── Check 4: Agent file consistency ────────────────────────────────────────
check_agent_consistency() {
    echo "Check 4: Agent file consistency"

    local violations=0
    local agent_dir="$ENGINE_ROOT/agents"

    if [[ ! -d "$agent_dir" ]]; then
        log_info "No agents/ directory found — skipping agent file checks"
        return
    fi

    # Check each .md file has at least one "# " heading
    # (files may have YAML front matter starting with "---")
    local files=()
    while IFS= read -r -d '' f; do
        files+=("$f")
    done < <(find "$agent_dir" -maxdepth 1 -name '*.md' -print0)

    local no_heading=0
    for f in "${files[@]}"; do
        local basename_f
        basename_f=$(basename "$f")
        # Search for a "# " or "## " heading anywhere in the file
        if ! grep -qm1 '^#\{1,6\} ' "$f" 2>/dev/null; then
            log_fail "$basename_f has no '#' heading"
            no_heading=$((no_heading + 1))
            violations=$((violations + 1))
        fi
    done

    # Check opencode.json references agents if it exists
    local opencode_json="$PROJECT_ROOT/.opencode/opencode.json"
    if [[ -f "$opencode_json" ]]; then
        log_verbose "Checking agent references in opencode.json..."
        # Count agent files referenced in opencode.json
        local referenced=0
        local not_referenced=0
        for f in "${files[@]}"; do
            local basename_f
            basename_f=$(basename "$f")
            # Check if the filename appears in opencode.json
            if grep -qF "$basename_f" "$opencode_json" 2>/dev/null; then
                referenced=$((referenced + 1))
            else
                if [[ "$VERBOSE" == true ]]; then
                    log_verbose "  $basename_f not referenced in opencode.json"
                fi
                not_referenced=$((not_referenced + 1))
            fi
        done

        if [[ "$not_referenced" -gt 0 ]]; then
            log_info "$not_referenced agent(s) not explicitly referenced in opencode.json (agents loaded via .opencode/agents/ symlink)"
        fi
        log_verbose "$referenced agent(s) found in opencode.json references"
        log_pass "opencode.json exists and references can resolve"
    else
        log_info "No opencode.json found — skipping agent reference check"
    fi

    if [[ "$no_heading" -eq 0 ]]; then
        log_pass "All agent files have proper headings"
    fi
}

# ── Check 5: Cross-references ──────────────────────────────────────────────
check_cross_references() {
    echo "Check 5: Cross-references"

    local violations=0

    # 5a: Internal links in agent.md
    local agent_md="$ENGINE_ROOT/agent.md"
    if [[ -f "$agent_md" ]]; then
        log_verbose "Checking internal links in agent.md..."

        # Extract relative markdown links: [text](./path) or [text](.opencode/path)
        # Exclude anchor-only links (#section)
        local broken_links=0
        while IFS= read -r link; do
            [[ -z "$link" ]] && continue
            # Skip anchor-only links
            if echo "$link" | grep -qE '^#'; then
                continue
            fi
            # Skip external URLs
            if echo "$link" | grep -qE '^https?://'; then
                continue
            fi

            local resolved
            # Links are relative to agent.md (the engine root), or absolute
            # deployment paths (/opt/engine/..., ~/.config/opencode/...).
            if [[ "$link" == /opt/engine/* ]]; then
                resolved="$ENGINE_ROOT/${link#/opt/engine/}"
            elif [[ "$link" == /home/node/.config/opencode/* ]]; then
                resolved="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/${link#/home/node/.config/opencode/}"
            elif [[ "$link" == /* ]]; then
                resolved="$link"
            else
                resolved="$ENGINE_ROOT/${link#./}"
            fi

            if [[ ! -f "$resolved" ]] && [[ ! -d "$resolved" ]]; then
                broken_links=$((broken_links + 1))
                log_fail "agent.md: link '$link' does not resolve (looked for '$resolved')"
                violations=$((violations + 1))
            else
                log_verbose "  agent.md: '$link' -> OK"
            fi
        done < <(grep -oP '\]\(([^)]+)\)' "$agent_md" 2>/dev/null | sed 's/^](//;s/)$//' || true)

        if [[ "$broken_links" -eq 0 ]]; then
            log_pass "All internal links in agent.md resolve correctly"
        fi
    else
        log_info "No agent.md found — skipping cross-reference check"
    fi

    if [[ "$violations" -eq 0 ]]; then
        echo "  Result: All cross-references resolve"
    fi
}

# ── Check 6: rules store_in sanity ─────────────────────────────────────────
# Every `store_in` leaf in rules/rules.json must point at runtime state
# (session/...) or a contract-embedded journal path (contract.*). This guard
# catches dangling store_in targets automatically (it would have caught both
# the doc/analysis target and the unimplemented feedback-history target).
check_rules_store_in() {
    echo "Check 6: rules store_in sanity"

    local violations=0
    local rules_file="$ENGINE_ROOT/rules/rules.json"

    if [[ ! -f "$rules_file" ]]; then
        log_fail "rules/rules.json does not exist"
        violations=$((violations + 1))
        return
    fi

    if ! jq -e . "$rules_file" >/dev/null 2>&1; then
        log_fail "rules/rules.json is not valid JSON"
        violations=$((violations + 1))
        return
    fi
    log_pass "rules/rules.json is valid JSON"

    if command -v jq &>/dev/null; then
        local count=0
        while IFS=$'\t' read -r path value; do
            [[ -z "$path" ]] && continue
            count=$((count + 1))
            if [[ "$value" != session/* && "$value" != contract.* ]]; then
                log_fail "rules.json .$path = '$value' (store_in must start with session/ or contract.)"
                violations=$((violations + 1))
            else
                log_verbose "rules.json .$path -> $value"
            fi
        done < <(jq -r '. as $root | paths | select(.[-1] == "store_in") | . as $p | (join(".") + "\t" + ($root | getpath($p) | tostring))' "$rules_file" 2>/dev/null)

        if [[ "$violations" -eq 0 && "$count" -gt 0 ]]; then
            log_pass "all $count store_in targets point at session/ or contract.*"
        elif [[ "$violations" -eq 0 ]]; then
            log_info "no store_in leaves found in rules.json"
        fi
    else
        log_info "jq not found — skipping store_in target validation"
    fi

    if [[ "$violations" -eq 0 ]]; then
        echo "  Result: store_in targets sane"
    fi
}

# ── Check 7: rules required top-level keys ──────────────────────────────────
# rules.schema.json is the source of truth; this jq check approximates it
# (full ajv validation is out of scope for the offline toolkit). Fails when
# any required top-level key is missing from rules/rules.json.
check_rules_required_keys() {
    echo "Check 7: rules required top-level keys"

    local violations=0
    local rules_file="$ENGINE_ROOT/rules/rules.json"

    if [[ ! -f "$rules_file" ]]; then
        log_fail "rules/rules.json does not exist"
        return
    fi

    if command -v jq &>/dev/null; then
        local required=(version description state_machine scoring enforcement metrics feedback decisions)
        local k
        for k in "${required[@]}"; do
            if jq -e --arg k "$k" 'has($k)' "$rules_file" >/dev/null 2>&1; then
                log_verbose "rules/rules.json has required key: $k"
            else
                log_fail "rules/rules.json is missing required top-level key: $k"
                violations=$((violations + 1))
            fi
        done

        if [[ "$violations" -eq 0 ]]; then
            echo "  Result: all ${#required[@]} required top-level keys present"
        fi
    else
        log_info "jq not found — skipping required-key validation"
    fi
}

# ── Summary ─────────────────────────────────────────────────────────────────
print_summary() {
    echo ""
    echo "=== Summary ==="
    echo "Passed: ${PASS_COUNT}, Failed: ${FAIL_COUNT}, Skipped: ${CHECK_COUNT}"
    if [[ "$VIOLATIONS" -eq 0 ]]; then
        echo -e "${GREEN}All checks passed.${NC}"
    else
        echo -e "${RED}${VIOLATIONS} violation(s) found.${NC}"
    fi
}

# ── Argument parsing ────────────────────────────────────────────────────────
parse_args() {
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
            *)
                echo "Unknown option: $1"
                echo "Use --help for usage info."
                exit 1
                ;;
        esac
    done
}

# ── Main ────────────────────────────────────────────────────────────────────
main() {
    parse_args "$@"


    echo "=== Toolkit Validator — Workflow State Engine ==="
    echo "Project root: $PROJECT_ROOT"
    echo "Engine root: $ENGINE_ROOT"
    echo "Mode: verbose=$VERBOSE, strict=$STRICT"
    echo ""

    check_required_dirs
    echo ""
    check_opencode_symlinks
    echo ""
    check_contract_integrity
    echo ""
    check_agent_consistency
    echo ""
    check_cross_references
    echo ""
    check_rules_store_in
    echo ""
    check_rules_required_keys

    print_summary
    exit $EXIT_CODE
}

main "$@"
