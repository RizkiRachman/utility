#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# check-conventions.sh — Validate project architecture conventions
#
# Usage:
#   ./scripts/check-conventions.sh          # Run all checks
#   ./scripts/check-conventions.sh --help   # Show usage
#   ./scripts/check-conventions.sh --verbose  # Detailed output
#   ./scripts/check-conventions.sh --strict   # Fail on first violation
#
# Exit codes:
#   0 — All checks pass
#   1 — One or more violations found
#
# Requirements:
#   - bash 4+
#   - jq (for JSON schema validation)
#
# This script is idempotent — safe to run multiple times.

set -euo pipefail

ENGINE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/paths.sh
. "$ENGINE_ROOT/scripts/lib/paths.sh"
PROJECT_ROOT="$(resolve_project_root "$ENGINE_ROOT")"
SESSION_DIR="$(resolve_session_dir "$PROJECT_ROOT")"
CURRENT_SESSION="$(session 2>/dev/null || echo "unknown")"

# ── Config ──────────────────────────────────────────────────────────────────
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

# ── Help ────────────────────────────────────────────────────────────────────
usage() {
    cat <<'USAGE'
check-conventions.sh — Validate project architecture conventions

SYNOPSIS
    ./scripts/check-conventions.sh [OPTIONS]

OPTIONS
    --help       Show this help message and exit
    --verbose    Print detailed output for each check
    --strict     Exit immediately on first violation

CHECKS
  1. Agent contract.json path consistency
      FAILs when an agent .md references contract/contract.json or the
      V1-era .opencode/orchestration/contract.json path; PASS otherwise.
      INFO when an agent references session/contract.json or
      contract.template.json (the correct V2 chain).

  2. JSON Schema validation
     Verifies contract/contract.schema.json exists and validates
     session/contract.json against it using jq (Draft 2020-12).

  3. Forbidden patterns
     Scans agent files for FQN patterns (src/main/java/)
     and other prohibited conventions.

  4. ArchUnit check
     If pom.xml or build.gradle exists, attempts to run architecture tests.
     Otherwise skips with info.

  5. Contract state sync check
     Verifies session/state.md contains Current Focus and
     Known Blockers sections.

EXIT CODES
  0   All checks pass
  1   One or more violations found

EXAMPLES
    ./scripts/check-conventions.sh
    ./scripts/check-conventions.sh --verbose
    ./scripts/check-conventions.sh --strict
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

# ── Check 1: Agent contract.json path consistency ──────────────────────────
check_agent_paths() {
    echo "---"
    echo "Check 1: Agent contract.json path consistency"
    echo "  FAIL: agent .md references contract/contract.json or the"
    echo "        V1-era .opencode/orchestration/contract.json"
    echo "  INFO: agent .md references session/contract.json or contract.template.json"

    local violations=0
    local correct_chain=0
    local agent_dir="$ENGINE_ROOT/agents"

    if [[ ! -d "$agent_dir" ]]; then
        log_info "No agents/ directory found — skipping check 1"
        return
    fi

    while IFS= read -r -d '' f; do
        local basename_f
        basename_f="$(basename "$f")"
        if grep -qE 'contract/contract\.json|\.opencode/orchestration/contract\.json' "$f" 2>/dev/null; then
            log_fail "$basename_f references a stale contract path (contract/contract.json or .opencode/orchestration/contract.json) — use session/contract.json or contract.template.json"
            violations=$((violations + 1))

            if [[ "$VERBOSE" == true ]]; then
                # Show the offending lines
                grep -nE 'contract/contract\.json|\.opencode/orchestration/contract\.json' "$f" | while IFS= read -r line; do
                    echo "    -> $basename_f:$line"
                done
            fi
        elif grep -qE 'session/contract\.json|contract\.template\.json' "$f" 2>/dev/null; then
            correct_chain=$((correct_chain + 1))
            log_info "$basename_f references the V2 contract chain (session/contract.json or contract.template.json)"
        fi
    done < <(find "$agent_dir" -maxdepth 1 -name '*.md' -print0)

    if [[ "$violations" -eq 0 && "$correct_chain" -gt 0 ]]; then
        log_pass "No stale contract paths; $correct_chain agent file(s) on the V2 chain"
    elif [[ "$violations" -eq 0 ]]; then
        log_pass "No stale contract paths in agent files"
    fi
}

# ── Check 2: JSON Schema validation ────────────────────────────────────────
check_json_schema() {
    echo "---"
    echo "Check 2: JSON Schema validation"

    local schema_file="$ENGINE_ROOT/contract/contract.schema.json"
    local contract_file="$SESSION_DIR/contract.json"

    if [[ ! -f "$schema_file" ]]; then
        log_fail "contract/contract.schema.json does not exist"
        if [[ "$VERBOSE" == true ]]; then
            echo "  -> Create a JSON Schema (Draft 2020-12) at contract/contract.schema.json"
            echo "  -> Reference: https://json-schema.org/specification.html"
        fi
        return
    fi

    if [[ ! -f "$contract_file" ]]; then
        log_fail "session/contract.json does not exist — cannot validate"
        return
    fi

    # Check it's valid JSON
    if ! jq empty "$schema_file" 2>/dev/null; then
        log_fail "contract/contract.schema.json is not valid JSON"
        if [[ "$VERBOSE" == true ]]; then
            jq empty "$schema_file" 2>&1 | sed 's/^/    -> /'
        fi
        return
    fi

    # Check it has required JSON Schema fields (Draft 2020-12 uses $schema)
    if ! jq -e 'has("$schema")' "$schema_file" >/dev/null 2>&1; then
        log_fail "contract/contract.schema.json missing \$schema keyword (not a valid JSON Schema)"
        return
    fi

    local schema_id
    schema_id="$(jq -r '."$schema" // empty' "$schema_file" 2>/dev/null)"

    if [[ -z "$schema_id" ]]; then
        log_info "contract/contract.schema.json has empty \$schema field"
    elif [[ "$schema_id" != "https://json-schema.org/draft/2020-12/schema" ]]; then
        log_info "contract/contract.schema.json \$schema is '$schema_id' (not Draft 2020-12)"
    fi

    # Validate contract.json against schema (no --argfile needed)
    if jq -e 'has("type")' "$schema_file" >/dev/null 2>&1; then
        local unknown_keys
        unknown_keys=$(jq -s '
            .[0].properties as $schemaProps |
            .[1] as $contract |
            [$contract | keys[] | select(. as $k | ($schemaProps | has($k)) | not) | select(startswith("$") | not)]
        ' "$schema_file" "$contract_file" 2>/dev/null)

        if [[ -z "$unknown_keys" || "$unknown_keys" == "[]" ]]; then
            log_pass "contract/contract.schema.json exists and validates session/contract.json"
        else
            log_fail "session/contract.json does not validate against contract/contract.schema.json"
            if [[ "$VERBOSE" == true ]]; then
                local clean_keys
                clean_keys=$(echo "$unknown_keys" | tr -d '[]" \n')
                echo "  -> Properties in contract.json not defined in schema: $clean_keys"
            fi
        fi
    else
        # Basic schema — use jv or fallback to jq check
        log_verbose "Schema type not 'object' — attempting structural check"

        # Use jq to validate: check that the schema has 'properties'
        if jq -e 'has("properties")' "$schema_file" >/dev/null 2>&1; then
            local unknown_keys
            unknown_keys=$(jq -s '
                .[0].properties as $schemaProps |
                .[1] as $contract |
                [$contract | keys[] | select(. as $k | ($schemaProps | has($k)) | not) | select(startswith("$") | not)]
            ' "$schema_file" "$contract_file" 2>/dev/null)

            if [[ -n "$unknown_keys" && "$unknown_keys" != "[]" ]]; then
                log_fail "contract.json has properties not defined in schema: $unknown_keys"
            else
                log_pass "contract/contract.schema.json exists and validates session/contract.json"
            fi
        else
            log_info "contract/contract.schema.json has no 'properties' — cannot deep validate"
            log_pass "contract/contract.schema.json exists as valid JSON Schema"
        fi
    fi
}

# ── Check 3: Forbidden patterns ────────────────────────────────────────────
check_forbidden_patterns() {
    echo "---"
    echo "Check 3: Forbidden patterns in agent files"

    local agent_dir="$ENGINE_ROOT/agents"
    local violations=0

    if [[ ! -d "$agent_dir" ]]; then
        log_info "No agents/ directory found — skipping check 3"
        return
    fi

    # Pattern A: FQN (src/main/java/)
    log_verbose "Checking for FQN pattern: src/main/java/"
    local fqn_files=()
    while IFS= read -r -d '' f; do
        if grep -q 'src/main/java/' "$f" 2>/dev/null; then
            fqn_files+=("$(basename "$f")")
        fi
    done < <(find "$agent_dir" -maxdepth 1 -name '*.md' -print0)

    if [[ ${#fqn_files[@]} -gt 0 ]]; then
        violations=$((violations + 1))
        local fqn_list
        fqn_list="$(printf "%s, " "${fqn_files[@]}")"
        fqn_list="${fqn_list%, }"
        log_fail "FQN pattern 'src/main/java/' found in: $fqn_list"
        if [[ "$VERBOSE" == true ]]; then
            for f in "${fqn_files[@]}"; do
                grep -n 'src/main/java/' "$agent_dir/$f" | while IFS= read -r line; do
                    echo "    -> $f:$line"
                done
            done
        fi
    else
        log_verbose "No FQN patterns found"
    fi



    if [[ "$violations" -eq 0 ]]; then
        log_pass "No forbidden patterns found in agent files"
    fi
}

# ── Check 4: ArchUnit (if Maven/Gradle) ───────────────────────────────────
check_archunit() {
    echo "---"
    echo "Check 4: ArchUnit / Architecture tests"

    local has_maven=false
    local has_gradle=false

    if [[ -f "$PROJECT_ROOT/pom.xml" ]]; then
        has_maven=true
        log_verbose "Found pom.xml (Maven project)"
    fi

    if [[ -f "$PROJECT_ROOT/build.gradle" ]] || [[ -f "$PROJECT_ROOT/build.gradle.kts" ]]; then
        has_gradle=true
        log_verbose "Found build.gradle (Gradle project)"
    fi

    if [[ "$has_maven" == false && "$has_gradle" == false ]]; then
        log_info "No Maven or Gradle build file found — skipping ArchUnit check"
        return
    fi

    # Check for ArchUnit dependency first
    if [[ "$has_maven" == true ]]; then
        if grep -q 'archunit' "$PROJECT_ROOT/pom.xml" 2>/dev/null; then
            log_verbose "ArchUnit dependency found in pom.xml"
            log_verbose "Running: mvn test -Dtest=\"*Architecture*\" -q"

            if mvn test -Dtest="*Architecture*" -q 2>/dev/null; then
                log_pass "ArchUnit architecture tests passed"
            else
                log_fail "ArchUnit architecture tests failed"
                if [[ "$VERBOSE" == true ]]; then
                    # Try again with output for diagnostics
                    mvn test -Dtest="*Architecture*" 2>&1 | tail -50 | sed 's/^/    -> /'
                fi
            fi
        else
            log_info "No ArchUnit dependency found in pom.xml — skipping ArchUnit check"
        fi
    elif [[ "$has_gradle" == true ]]; then
        if grep -q 'archunit' "$PROJECT_ROOT/build.gradle" 2>/dev/null ||
           grep -q 'archunit' "$PROJECT_ROOT/build.gradle.kts" 2>/dev/null; then
            log_verbose "ArchUnit dependency found in build.gradle"
            log_verbose "Running: ./gradlew test --tests \"*Architecture*\" -q"

            if ./gradlew test --tests "*Architecture*" -q 2>/dev/null; then
                log_pass "ArchUnit architecture tests passed"
            else
                log_fail "ArchUnit architecture tests failed"
            fi
        else
            log_info "No ArchUnit dependency found in build.gradle — skipping ArchUnit check"
        fi
    fi
}

# ── Check 5: State.md sync ─────────────────────────────────────────────────
check_state_md() {
    echo "---"
    echo "Check 5: Contract state sync check"

    local state_file="$SESSION_DIR/state.md"

    if [[ ! -f "$state_file" ]]; then
        log_fail "session/state.md does not exist"
        return
    fi

    local violations=0

    # Check for "Current Focus" section
    if grep -qi '^##\s*Current Focus' "$state_file" >/dev/null 2>&1; then
        log_verbose "Found 'Current Focus' section"
    else
        log_fail "session/state.md missing 'Current Focus' section"
        violations=$((violations + 1))
    fi

    # Check for "Known Blockers" section
    if grep -qi '^##\s*Known Blockers' "$state_file" >/dev/null 2>&1; then
        log_verbose "Found 'Known Blockers' section"
    else
        log_fail "session/state.md missing 'Known Blockers' section"
        violations=$((violations + 1))
    fi

    # Check that Current Focus has content (not empty)
    if grep -qi '^##\s*Current Focus' "$state_file" >/dev/null 2>&1; then
        local focus_content
        # Use awk to extract lines between "## Current Focus" and next "## " heading.
        # Portable across macOS and Linux (avoids head -n -1 which fails on macOS).
        focus_content="$(awk '/^## *Current Focus/{flag=1; next} /^## /{flag=0} flag{print}' "$state_file" 2>/dev/null | tr -d '[:space:]' || true)"
        if [[ -z "$focus_content" ]]; then
            log_fail "'Current Focus' section is empty (has heading but no content)"
            violations=$((violations + 1))
        fi
    fi

    # Check that Known Blockers has content or placeholder
    if grep -qi '^##\s*Known Blockers' "$state_file" >/dev/null 2>&1; then
        local blockers_content
        blockers_content="$(awk '/^## *Known Blockers/{flag=1; next} /^## /{flag=0} flag{print}' "$state_file" 2>/dev/null | tr -d '[:space:]' || true)"
        if [[ -z "$blockers_content" ]]; then
            log_fail "'Known Blockers' section is empty (has heading but no content)"
            violations=$((violations + 1))
        fi
    fi

    if [[ "$violations" -eq 0 ]]; then
        log_pass "session/state.md has Current Focus and Known Blockers sections"
    fi
}

# ── Check 6: session/ integrity ─────────────────────────────────────────────
check_session_archive() {
    echo "---"
    echo "Check 6: session/ integrity"

    local session_dir="$SESSION_DIR"
    local violations=0

    if [[ ! -d "$session_dir" ]]; then
        log_fail "session/ directory does not exist"
        return
    fi

    for required in contract.json state.md; do
        if [[ -f "$session_dir/$required" ]]; then
            log_verbose "session/$required exists"
        else
            log_fail "session/$required does not exist"
            violations=$((violations + 1))
        fi
    done

    if [[ "$violations" -eq 0 ]]; then
        log_pass "session/ contains contract.json and state.md"
    fi

    if [[ "$violations" -gt 0 ]]; then
        CHECK_COUNT=$((CHECK_COUNT + violations))
    fi
}

# ── Summary ─────────────────────────────────────────────────────────────────
print_summary() {
    local total_checks=$((CHECK_COUNT + PASS_COUNT + FAIL_COUNT))
    echo "---"
    echo "Summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed, ${CHECK_COUNT} skipped"
    if [[ "$VIOLATIONS" -eq 0 ]]; then
        echo -e "${GREEN}All checks passed.${NC}"
    else
        echo -e "${RED}${VIOLATIONS} violation(s) found.${NC}"
    fi
}

# ── Main ────────────────────────────────────────────────────────────────────
main() {
    # Parse arguments
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
                echo "Use --help for usage information."
                exit 1
                ;;
        esac
    done

    echo "=== Convention Checker — Workflow State Engine ==="
    echo "Project root: $PROJECT_ROOT"
    echo "Engine root: $ENGINE_ROOT"
    echo "Mode: verbose=$VERBOSE, strict=$STRICT"
    echo ""

    check_agent_paths
    check_json_schema
    check_forbidden_patterns
    check_archunit
    check_state_md
    check_session_archive

    echo ""
    print_summary

    exit "$EXIT_CODE"
}

main "$@"
