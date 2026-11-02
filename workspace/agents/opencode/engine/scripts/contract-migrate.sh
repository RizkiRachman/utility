#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# contract-migrate.sh — Migrate contract JSON files between versions
#
# Reads a contract file, detects its version, and migrates it to a target
# version using contract/contract.template.json as the reference structure.
#
# Usage:
#   ./scripts/contract-migrate.sh --file session/br/contract.json
#   ./scripts/contract-migrate.sh --file contract.json --from 0.7.0 --to 0.8.0
#   ./scripts/contract-migrate.sh --file contract.json --validate
#   ./scripts/contract-migrate.sh --file contract.json --backup
#   ./scripts/contract-migrate.sh --file contract.json --verbose
#   ./scripts/contract-migrate.sh --file contract.json --dry-run
#   ./scripts/contract-migrate.sh --help
#
# Exit codes:
#   0 — Migration successful (or no migration needed)
#   1 — Migration completed with warnings
#   2 — Error (missing deps, invalid opts, file not found, etc.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# ── Config ──────────────────────────────────────────────────────────────────
CONTRACT_FILE=""
FROM_VERSION=""
TO_VERSION=""
DO_VALIDATE=false
DO_BACKUP=false
HELP=false
VERBOSE=false
DRY_RUN=false
EXIT_CODE=0
VALIDATE_SCRIPT="$PROJECT_DIR/scripts/validate-contract.sh"
TEMPLATE_FILE="$PROJECT_DIR/contract/contract.template.json"

# Color output (disable if not a terminal)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    CYAN=''
    BOLD=''
    NC=''
fi

# ── Help ────────────────────────────────────────────────────────────────────
usage() {
    cat <<'USAGE'
contract-migrate.sh — Migrate contract JSON files between versions

SYNOPSIS
    ./scripts/contract-migrate.sh --file PATH [OPTIONS]

OPTIONS
    --file PATH      Contract JSON file to migrate (required)
    --from VERSION   Source version (auto-detect from file if omitted)
    --to VERSION     Target version (default: read from contract.template.json)
    --validate       Run validate-contract.sh after migration
    --backup         Create a .bak copy before modifying
    --help           Show this help message and exit
    --verbose        Detailed output during migration
    --dry-run        Preview changes without modifying file

DESCRIPTION
    Migrates contract JSON files from one version to another using
    contract/contract.template.json as the reference for the target structure.

    The --from version is auto-detected from the file's contract_version
    field if not specified. The --to version defaults to the version in
    contract.template.json if not specified.

    Supported migrations:
      v0.7.0 -> v0.8.0:
        - Add decisions.confidence_scores[] (array) if missing
        - Add outputs.debt_ledger[] (array) if missing
        - Update contract_version and state_machine_version
        - Fill in missing top-level keys by merging with template

EXIT CODES
    0   Migration successful (or no migration needed)
    1   Migration completed with warnings
    2   Error (missing dependencies, invalid options, file not found, etc.)

EXAMPLES
    ./scripts/contract-migrate.sh --file session/contract.json
    ./scripts/contract-migrate.sh --file contract.json --from 0.7.0 --to 0.8.0
    ./scripts/contract-migrate.sh --file contract.json --validate
    ./scripts/contract-migrate.sh --file contract.json --backup --verbose
    ./scripts/contract-migrate.sh --file contract.json --dry-run --verbose

USAGE
}

# ── Logging helpers ─────────────────────────────────────────────────────────
# log_pass/log_fail/log_info/log_verbose come from scripts/lib.
# log_dry stays local: it is gated on DRY_RUN here, unlike the lib's
# unconditional variant.

log_dry() {
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "  ${CYAN}[DRY-RUN]${NC} $1"
    fi
}

log_section() {
    echo ""
    echo -e "${BOLD}$1${NC}"
    echo "  $(printf '%*s' "$((${#1} + 2))" '' | tr ' ' '─')"
}

log_change() {
    local field="$1"
    local action="$2"
    echo -e "  ${GREEN}✓${NC} ${field}: ${action}"
}

# ── Helper functions ────────────────────────────────────────────────────────

# Detect version from contract file
detect_version() {
    local file="$1"
    local version
    version=$(jq -r '.contract_version // empty' "$file" 2>/dev/null || true)
    if [[ -z "$version" ]]; then
        version=$(jq -r '.version // empty' "$file" 2>/dev/null || true)
    fi
    echo "$version"
}

# Read target version from template
read_target_version() {
    local template="$1"
    if [[ ! -f "$template" ]]; then
        echo ""
        return
    fi
    jq -r '.contract_version // "0.8.0"' "$template" 2>/dev/null || echo "0.8.0"
}

# Check if two semver-like versions are different
version_ne() {
    local v1="$1"
    local v2="$2"
    # Strip leading 'v' if present
    v1="${v1#v}"
    v2="${v2#v}"
    [[ "$v1" != "$v2" ]]
}

# Migrate v0.7.0 -> v0.8.0
migrate_070_to_080() {
    local input_file="$1"
    local output_file="$2"
    local template="$3"

    log_info "Applying v0.7.0 -> v0.8.0 migration"

    # Read the contract
    local contract
    contract=$(cat "$input_file")

    # Read template for reference keys (merged later if missing)
    local template_json="{}"
    if [[ -f "$template" ]]; then
        template_json=$(cat "$template")
        log_verbose "Loaded template from: ${template}"
    fi

    local changes_made=false

    # --- Add decisions.confidence_scores[] if missing ---
    local has_confidence_scores
    has_confidence_scores=$(echo "$contract" | jq 'has("decisions") and (.decisions | has("confidence_scores"))' 2>/dev/null || echo "false")
    if [[ "$has_confidence_scores" != "true" ]]; then
        log_change "decisions.confidence_scores" "added (empty array)"
        if echo "$contract" | jq 'has("decisions")' 2>/dev/null | grep -q true; then
            contract=$(echo "$contract" | jq '.decisions.confidence_scores = []' 2>/dev/null)
        else
            contract=$(echo "$contract" | jq '.decisions = {confidence_scores: []}' 2>/dev/null)
        fi
        changes_made=true
    else
        log_verbose "decisions.confidence_scores already exists — skipping"
    fi

    # --- Add outputs.debt_ledger[] if missing ---
    local has_debt_ledger
    has_debt_ledger=$(echo "$contract" | jq 'has("outputs") and (.outputs | has("debt_ledger"))' 2>/dev/null || echo "false")
    if [[ "$has_debt_ledger" != "true" ]]; then
        log_change "outputs.debt_ledger" "added (empty array)"
        if echo "$contract" | jq 'has("outputs")' 2>/dev/null | grep -q true; then
            contract=$(echo "$contract" | jq '.outputs.debt_ledger = []' 2>/dev/null)
        else
            contract=$(echo "$contract" | jq '.outputs = {debt_ledger: []}' 2>/dev/null)
        fi
        changes_made=true
    else
        log_verbose "outputs.debt_ledger already exists — skipping"
    fi

    # --- Update contract_version and state_machine_version ---
    local target_version="${TO_VERSION#v}"
    target_version="${target_version#v}"
    local cur_contract_ver
    cur_contract_ver=$(echo "$contract" | jq -r '.contract_version // ""' 2>/dev/null)
    if [[ -n "$cur_contract_ver" ]] && version_ne "$cur_contract_ver" "$target_version"; then
        log_change "contract_version" "${cur_contract_ver} -> v${target_version}"
        contract=$(echo "$contract" | jq --arg v "v${target_version}" '.contract_version = $v' 2>/dev/null)
        changes_made=true
    elif [[ -z "$cur_contract_ver" ]]; then
        log_change "contract_version" "set to v${target_version}"
        contract=$(echo "$contract" | jq --arg v "v${target_version}" '.contract_version = $v' 2>/dev/null)
        changes_made=true
    fi

    # Also update state_machine_version to match if present
    local cur_sm_ver
    cur_sm_ver=$(echo "$contract" | jq -r '.state_machine_version // ""' 2>/dev/null)
    if [[ -n "$cur_sm_ver" ]] && version_ne "$cur_sm_ver" "$target_version"; then
        log_change "state_machine_version" "${cur_sm_ver} -> v${target_version}"
        contract=$(echo "$contract" | jq --arg v "v${target_version}" '.state_machine_version = $v' 2>/dev/null)
        changes_made=true
    fi

    # --- Merge any missing top-level keys from template ---
    if [[ -f "$template" ]]; then
        local template_keys
        template_keys=$(echo "$template_json" | jq -r 'keys[]' 2>/dev/null || true)
        local merged=false
        while IFS= read -r key; do
            local has_key
            has_key=$(echo "$contract" | jq --arg k "$key" 'has($k)' 2>/dev/null || echo "false")
            if [[ "$has_key" != "true" ]]; then
                # Skip meta keys that don't belong in migrated contracts
                if [[ "$key" == "_comment" || "$key" == "_template_version" ]]; then
                    continue
                fi
                log_change "top-level.${key}" "added from template"
                # Extract the key's value from template, add to contract
                local val
                val=$(echo "$template_json" | jq --arg k "$key" '.[$k]' 2>/dev/null)
                contract=$(echo "$contract" | jq --arg k "$key" --argjson v "$val" '. + {($k): $v}' 2>/dev/null)
                merged=true
            fi
        done <<< "$template_keys"
        if [[ "$merged" == true ]]; then
            changes_made=true
        fi
    fi

    # Write output
    if [[ "$DRY_RUN" == true ]]; then
        log_dry "Would write migrated contract to: ${output_file}"
        if [[ "$VERBOSE" == true ]]; then
            echo ""
            echo "  --- Migrated contract preview ---"
            echo "$contract" | jq '.' 2>/dev/null || echo "$contract"
            echo "  --- end preview ---"
        fi
    else
        echo "$contract" | jq '.' > "$output_file" 2>/dev/null || {
            log_fail "Failed to write migrated contract to: ${output_file}"
            return 1
        }
        log_pass "Wrote migrated contract: ${output_file}"
    fi

    if [[ "$changes_made" == false ]]; then
        log_info "No changes needed for v0.7.0 -> v0.8.0 migration"
    fi

    return 0
}

# ── Main ────────────────────────────────────────────────────────────────────
main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                HELP=true
                shift
                ;;
            --file)
                shift
                CONTRACT_FILE="$1"
                shift
                ;;
            --from)
                shift
                FROM_VERSION="$1"
                shift
                ;;
            --to)
                shift
                TO_VERSION="$1"
                shift
                ;;
            --validate)
                DO_VALIDATE=true
                shift
                ;;
            --backup)
                DO_BACKUP=true
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            *)
                echo -e "${RED}Unknown option:${NC} $1" >&2
                echo "Try '$(basename "$0") --help' for more info." >&2
                exit 2
                ;;
        esac
    done

    if [[ "$HELP" == true ]]; then
        usage
        exit 0
    fi

    # --- Pre-flight checks ---

    # --file is required
    if [[ -z "$CONTRACT_FILE" ]]; then
        echo -e "${RED}Error:${NC} --file PATH is required" >&2
        echo "Try '$(basename "$0") --help' for more info." >&2
        exit 2
    fi

    # Resolve relative path
    if [[ ! "$CONTRACT_FILE" = /* ]]; then
        CONTRACT_FILE="$PROJECT_DIR/$CONTRACT_FILE"
    fi

    if [[ ! -f "$CONTRACT_FILE" ]]; then
        log_fail "Contract file not found: ${CONTRACT_FILE}"
        exit 2
    fi

    # Check for jq
    if ! command -v jq &>/dev/null; then
        log_fail "jq is required but not installed."
        exit 2
    fi

    # Check template
    if [[ ! -f "$TEMPLATE_FILE" ]]; then
        log_fail "Contract template not found: ${TEMPLATE_FILE}"
        exit 2
    fi

    # Validate input file is valid JSON
    if ! jq -e '.' "$CONTRACT_FILE" >/dev/null 2>&1; then
        log_fail "Invalid JSON in contract file: ${CONTRACT_FILE}"
        exit 2
    fi

    log_section "contract-migrate.sh — Contract Migration"
    echo -e "  File:           ${CYAN}${CONTRACT_FILE}${NC}"
    echo -e "  Backup:         ${CYAN}${DO_BACKUP}${NC}"
    echo -e "  Validate:       ${CYAN}${DO_VALIDATE}${NC}"
    echo -e "  Verbose:        ${CYAN}${VERBOSE}${NC}"
    echo -e "  Dry-run:        ${CYAN}${DRY_RUN}${NC}"

    # --- Detect versions ---
    local detected_version
    detected_version=$(detect_version "$CONTRACT_FILE")

    if [[ -z "$FROM_VERSION" ]]; then
        if [[ -n "$detected_version" ]]; then
            FROM_VERSION="$detected_version"
            log_info "Auto-detected source version: ${FROM_VERSION}"
        else
            log_info "No version detected in file — assuming v0.7.0"
            FROM_VERSION="0.7.0"
        fi
    fi

    if [[ -z "$TO_VERSION" ]]; then
        local template_version
        template_version=$(read_target_version "$TEMPLATE_FILE")
        if [[ -n "$template_version" ]]; then
            TO_VERSION="$template_version"
            log_info "Target version from template: ${TO_VERSION}"
        else
            log_info "No target version in template — defaulting to 0.8.0"
            TO_VERSION="0.8.0"
        fi
    fi

    echo -e "  From:           ${CYAN}v${FROM_VERSION#v}${NC}"
    echo -e "  To:             ${CYAN}v${TO_VERSION#v}${NC}"

    # --- Check if migration is needed ---
    if ! version_ne "$FROM_VERSION" "$TO_VERSION"; then
        log_info "Source version (v${FROM_VERSION#v}) already matches target (v${TO_VERSION#v}) — no migration needed"
        if [[ "$DO_VALIDATE" == true ]] && [[ -f "$VALIDATE_SCRIPT" ]]; then
            log_section "Post-Migration Validation"
            if [[ "$DRY_RUN" == true ]]; then
                log_dry "Would run: ${VALIDATE_SCRIPT} --file ${CONTRACT_FILE}"
            else
                bash "$VALIDATE_SCRIPT" --file "$CONTRACT_FILE" || {
                    log_info "Validation completed with warnings"
                }
            fi
        fi
        exit 0
    fi

    # --- Backup ---
    local backup_file="${CONTRACT_FILE}.bak"
    if [[ "$DO_BACKUP" == true ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            log_dry "Would create backup: ${backup_file}"
        else
            cp "$CONTRACT_FILE" "$backup_file"
            log_pass "Backup created: ${backup_file}"
        fi
    fi

    # --- Determine migration path ---
    local src_ver="${FROM_VERSION#v}"
    local tgt_ver="${TO_VERSION#v}"

    # For now, we support incremental migrations from any source up to target
    # This is a linear chain: 0.7.0 -> 0.8.0
    # Future: add more migration steps in order

    local temp_file
    temp_file=$(mktemp)
    cp "$CONTRACT_FILE" "$temp_file"

    local migration_applied=false

    log_section "Applying Migrations"

    # Migrate 0.7.0 -> 0.8.0 if relevant
    if [[ "$src_ver" == "0.7.0" ]] || [[ "$src_ver" < "0.8.0" && "$src_ver" > "0.0.0" ]] 2>/dev/null; then
        if version_ne "0.7.0" "$tgt_ver"; then
            # Check if we need 0.7.0 -> 0.8.0 (either starting at 0.7.0 or going past it)
            if [[ "$src_ver" == "0.7.0" ]] || [[ "$src_ver" < "0.8.0" && "$src_ver" > "0.7.0" ]] 2>/dev/null || true; then
                log_section "Migration Step: 0.7.0 -> 0.8.0"
                if migrate_070_to_080 "$temp_file" "$temp_file" "$TEMPLATE_FILE"; then
                    migration_applied=true
                    src_ver="0.8.0"
                else
                    log_fail "Migration step 0.7.0 -> 0.8.0 failed"
                    rm -f "$temp_file"
                    exit 2
                fi
            fi
        fi
    fi

    # If the source version isn't recognized, try applying all known migrations
    if [[ "$migration_applied" == false ]] && version_ne "$src_ver" "$tgt_ver"; then
        log_info "Attempting incremental migrations from v${FROM_VERSION#v} to v${TO_VERSION#v}"

        # Apply chain: each step bumps the version. We start from detected or FROM_VERSION.
        local cur_ver="$src_ver"

        if [[ "$cur_ver" == "0.7.0" ]] || [[ "$cur_ver" < "0.8.0" ]] 2>/dev/null; then
            if version_ne "$cur_ver" "$tgt_ver"; then
                log_section "Migration Step: 0.7.0 -> 0.8.0"
                if migrate_070_to_080 "$temp_file" "$temp_file" "$TEMPLATE_FILE"; then
                    migration_applied=true
                    cur_ver="0.8.0"
                else
                    log_fail "Migration step 0.7.0 -> 0.8.0 failed"
                    rm -f "$temp_file"
                    exit 2
                fi
            fi
        fi

        if version_ne "$cur_ver" "$tgt_ver"; then
            log_info "No direct migration path from v${FROM_VERSION#v} -> v${TO_VERSION#v}"
            log_info "Applied up to: v${cur_ver}"
            # Write whatever we have
            if [[ "$DRY_RUN" == false ]]; then
                cp "$temp_file" "$CONTRACT_FILE"
            fi
        fi
    fi

    # --- Write final result ---
    if [[ "$migration_applied" == true ]]; then
        if [[ "$DRY_RUN" != true ]]; then
            cp "$temp_file" "$CONTRACT_FILE"
            log_pass "Migration applied: v${FROM_VERSION#v} -> v${TO_VERSION#v}"
        else
            log_dry "Migration would be applied: v${FROM_VERSION#v} -> v${TO_VERSION#v}"
        fi
    fi

    rm -f "$temp_file"

    # --- Post-migration validation ---
    if [[ "$DO_VALIDATE" == true ]] && [[ -f "$VALIDATE_SCRIPT" ]]; then
        log_section "Post-Migration Validation"
        if [[ "$DRY_RUN" == true ]]; then
            log_dry "Would run: ${VALIDATE_SCRIPT} --file ${CONTRACT_FILE}"
        else
            log_info "Running validate-contract.sh..."
            bash "$VALIDATE_SCRIPT" --file "$CONTRACT_FILE" || {
                log_info "Validation completed with warnings (score may be below threshold)"
            }
        fi
    fi

    log_section "Done"
    if [[ "$migration_applied" == true ]]; then
        log_pass "Migration complete: v${FROM_VERSION#v} -> v${TO_VERSION#v}"
    else
        log_info "No migration was applied"
    fi

    exit "$EXIT_CODE"
}

main "$@"
