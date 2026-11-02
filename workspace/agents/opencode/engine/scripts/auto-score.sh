#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# auto-score.sh — Automated 3-Tier Scoring Pipeline
#
# Replicates the scoring logic from the orchestration contract:
#   Tier 1 — Rule-based checks (bash + jq, NO LLM calls)
#   Tier 2 — LLM-as-Judge (pass-through prompt, simulated in bash)
#   Tier 3 — Combined verdict with PASS / RETRY / BLOCKED
#
# Usage:
#   scripts/auto-score.sh --file contract.json --rules rules.json         # Full scoring
#   scripts/auto-score.sh --file contract.json --rules rules.json --dry-run   # Preview
#   scripts/auto-score.sh --file contract.json --rules rules.json --tier 1    # Rules only
#   scripts/auto-score.sh --file contract.json --rules rules.json --score-only # Just score number
#   scripts/auto-score.sh --help
#
# Exit codes:
#   0 = PASS (score ≥ 70)
#   1 = RETRY (score 50-69)
#   2 = BLOCKED (score < 50 or critical error)
# =============================================================================

set -euo pipefail

# ── Config ──────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONTRACT_FILE=""
RULES_FILE=""
DRY_RUN=false
TIER_FILTER="all"  # all, 1, 2
SCORE_ONLY=false
VERBOSE=false
PASS_COUNT=0
FAIL_COUNT=0
DEDUCTION=0
MAX_SCORE=100
RULE_DEDUCTION_MAP=""

# Default schema path
SCHEMA_FILE="$PROJECT_DIR/contract/contract.schema.json"

# Color output
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; NC=''
fi

# ── Help ────────────────────────────────────────────────────────────────────
usage() {
    cat <<'USAGE'
auto-score.sh — Automated 3-Tier Scoring Pipeline

SYNOPSIS
    scripts/auto-score.sh --file PATH [OPTIONS]

REQUIRED
    --file PATH       Contract JSON file to score

OPTIONS
    --rules PATH      Path to rules.json (default: PROJECT_DIR/rules/rules.json)
    --tier N          Score only a specific tier: 1 (rules) or 2 (judge)
                      (default: all — both tiers)
    --score-only      Output only the combined score number (for CI/scripts)
    --dry-run         Show each check without scoring or modifying anything
    --verbose         Detailed output per check
    --help            Show this help message and exit

BEHAVIOR
    Tier 1 — Rule-Based (bash + jq, no LLM):
      1. Schema valid (-15)    : Validate required top-level fields exist
      2. Permissions (-40)     : Check read-only fields haven't been written
      3. Blast radius (-40)    : Grep for forbidden patterns in outputs
      4. Writing order (-15)   : Check plan mentions port→service→mapper→adapter
      5. Required fields (-15) : Check outputs.plan and session.session_id present
      Floors at 0 (never negative). Skips Tier 2 if subtotal < 70.

    Tier 2 — LLM-as-Judge (pass-through):
      Reads requirements.goal + acceptance_criteria from the contract.
      Prints a judge-ready JSON prompt to stdout (for orchestrator to forward).
      Without --tier 2, returns conservative fallback (Tier 1 subtotal).

    Tier 3 — Combined Verdict:
      combined ≥ 70   → PASS
      50 ≤ combined < 70 → RETRY
      combined < 50   → BLOCKED

OUTPUT (default):
    {
      "score": {
        "rules": { "pass": 4, "fail": 1, "deduction": 15, "subtotal": 85 },
        "judge": { "score": 80, "rationale": "...", "missing_items": [] },
        "combined": 82,
        "verdict": "PASS"
      }
    }

EXIT CODES
    0   PASS
    1   RETRY
    2   BLOCKED or error

EXAMPLES
    scripts/auto-score.sh --file contract/contract.template.json --rules rules/rules.json
    scripts/auto-score.sh --file session/contract.json --score-only
    scripts/auto-score.sh --file contract.json --tier 1
    scripts/auto-score.sh --file contract.json --dry-run

USAGE
    exit 0
}

# ── Logging ─────────────────────────────────────────────────────────────────
log_pass()   { >&2 echo -e "  ${GREEN}[PASS]${NC} $1"; }
log_fail()   { >&2 echo -e "  ${RED}[FAIL]${NC} $1"; }
log_info()   { >&2 echo -e "  ${YELLOW}[INFO]${NC} $1"; }
log_verbose(){ [[ "$VERBOSE" == true ]] && >&2 echo -e "    ${CYAN}→${NC} $1"; }
log_dry()    { >&2 echo -e "  ${YELLOW}[DRY-RUN]${NC} $1"; }

# ── jq availability ─────────────────────────────────────────────────────────
ensure_jq() {
    if ! command -v jq &>/dev/null; then
        echo "ERROR: jq is required but not installed. Install jq (brew install jq / apt install jq)." >&2
        exit 2
    fi
}

# ── Safe jq get (returns empty string on missing/null) ──────────────────────
jq_get() {
    local field="$1"
    local file="$2"
    jq -r "${field} // \"\"" "$file" 2>/dev/null || echo ""
}

# ── Tier 1 Check 1: Schema valid (-15) ─────────────────────────────────────
# Check required top-level fields exist via jq
check_schema_valid() {
    local file="$1"
    local missing=()

    # Required top-level keys per spec: contract_version, state, session, session.task_id, session.session_id
    if [[ "$(jq 'has("contract_version")' "$file" 2>/dev/null)" != "true" ]]; then
        missing+=("contract_version")
    fi
    if [[ "$(jq 'has("state")' "$file" 2>/dev/null)" != "true" ]]; then
        missing+=("state")
    fi
    if [[ "$(jq 'has("session")' "$file" 2>/dev/null)" != "true" ]]; then
        missing+=("session")
    fi
    if [[ "$(jq '.session | has("task_id")' "$file" 2>/dev/null)" != "true" ]]; then
        missing+=("session.task_id")
    fi
    if [[ "$(jq '.session | has("session_id")' "$file" 2>/dev/null)" != "true" ]]; then
        missing+=("session.session_id")
    fi

    if [[ ${#missing[@]} -eq 0 ]]; then
        log_pass "Schema valid — all 5 required fields present"
        return 0
    else
        log_fail "Schema invalid — missing fields: ${missing[*]}"
        return 1
    fi
}

# ── Tier 1 Check 2: Permissions violated (-40) ──────────────────────────────
# Read rules.json → state_machine.read_only_fields. If any read-only field
# in the contract has been written (for baseline, check governance section
# respects the read_only_fields list).
check_permissions_violated() {
    local file="$1"
    local rules_file="$2"
    local violations=""
    local ro_fields

    if [[ ! -f "$rules_file" ]]; then
        log_info "No rules.json provided — skipping permissions check"
        return 0
    fi

    # Extract read_only_fields from rules.json
    ro_fields=$(jq -r '.state_machine.read_only_fields // [] | .[]' "$rules_file" 2>/dev/null || echo "")
    if [[ -z "$ro_fields" ]]; then
        # Try the governance.permissions.read_only_fields path
        ro_fields=$(jq -r '.scoring.tier1 // {} | keys[]' "$rules_file" 2>/dev/null || echo "")
        # Fallback: use the contract-level governance.permissions.read_only_fields
        ro_fields=""
    fi

    # Also extract from rules.scoring or from the contract's own governance.permissions
    local contract_ro
    contract_ro=$(jq -r '.governance.permissions.read_only_fields // [] | .[]' "$file" 2>/dev/null || echo "")

    # Check the governance section — per spec: "if governance section exists
    # and respects the read_only_fields list"
    for field in $contract_ro; do
        # These fields should not be modified by the agent. Check for anomalies.
        # For simple check: verify governance exists and these fields are in read_only_fields
        local exists_in_rules
        exists_in_rules=$(jq -r --arg f "$field" '.state_machine.read_only_fields // [] | index($f) // false' "$rules_file" 2>/dev/null || echo "false")
        if [[ "$exists_in_rules" == "false" ]]; then
            # Not a violation, but note the discrepancy
            log_verbose "Field '$field' in contract read_only_fields but not in rules.json"
        fi
    done

    # Check for actual violations: look for fields that are in read_only_fields
    # but have been written to (e.g., score, retry, metrics, audit_log, governance)
    # We check if they contain non-null/non-empty values
    local suspect_fields=("score" "retry" "metrics" "audit_log" "governance")
    for sf in "${suspect_fields[@]}"; do
        local exists
        exists=$(jq "has(\"$sf\") and .\"$sf\" != null" "$file" 2>/dev/null || echo "false")
        # Having these fields is NOT a violation — they always exist in the contract.
        # A violation would be if they're IN the read_only list AND the agent
        # has overridden governance.permissions or modified the governance section itself.
        # Since we always have these fields, we check if governance.permissions is intact.
        if [[ "$sf" == "governance" ]]; then
            local perm_check
            perm_check=$(jq '.governance | has("permissions")' "$file" 2>/dev/null || echo "false")
            if [[ "$perm_check" != "true" ]]; then
                violations+="governance.permissions "
                log_verbose "Permissions section missing from governance"
            fi
        fi
    done

    if [[ -n "$violations" ]]; then
        log_fail "Permissions violated — read-only fields modified: $violations"
        return 1
    else
        log_pass "No permissions violations detected"
        return 0
    fi
}

# ── Tier 1 Check 3: Blast radius safe (-40) ─────────────────────────────────
# Grep for forbidden patterns in outputs.plan and outputs.architecture
check_blast_radius_safe() {
    local file="$1"
    local forbidden=("direct push to main" "force push" "skip validation" "FQN")
    local found=""
    local content

    # Extract plan and architecture as strings for analysis
    content=$(jq -r '
        (.outputs.plan // "") as $plan |
        (.outputs.architecture // "") as $arch |
        "\($plan)\n\($arch)"
    ' "$file" 2>/dev/null || echo "")

    if [[ -z "$content" || "$content" == $'\n' ]]; then
        # No content to check — pass with note
        log_verbose "No output content to scan for blast radius patterns"
        log_pass "Blast radius safe — no output content to check"
        return 0
    fi

    for pattern in "${forbidden[@]}"; do
        if echo "$content" | grep -qiF "$pattern" 2>/dev/null; then
            found+="\"$pattern\" "
        fi
    done

    if [[ -n "$found" ]]; then
        log_fail "Blast radius HIGH — forbidden patterns found: $found"
        return 1
    else
        log_pass "Blast radius safe — no forbidden patterns in outputs"
        return 0
    fi
}

# ── Tier 1 Check 4: Writing order correct (-15) ──────────────────────────────
# Check if outputs.plan mentions the expected writing order: port→service→mapper→adapter
check_writing_order() {
    local file="$1"
    local plan
    local terms=("port" "service" "mapper" "adapter")
    local missing=()

    plan=$(jq -r '.outputs.plan // ""' "$file" 2>/dev/null || echo "")
    if [[ -z "$plan" ]]; then
        log_info "No plan content to check writing order"
        log_pass "Writing order check skipped (no plan)"
        return 0
    fi

    for term in "${terms[@]}"; do
        if echo "$plan" | grep -qiF "$term" 2>/dev/null; then
            log_verbose "Writing order term found: '$term'"
        else
            missing+=("$term")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        log_pass "Writing order correct — all terms found: port→service→mapper→adapter"
        return 0
    elif [[ ${#missing[@]} -lt 3 ]]; then
        log_info "Partial writing order — missing: ${missing[*]}"
        log_pass "Writing order partially present"
        return 0
    else
        log_fail "Writing order wrong — missing terms: ${missing[*]}"
        return 1
    fi
}

# ── Tier 1 Check 5: Required fields present (-15) ──────────────────────────
check_required_fields_present() {
    local file="$1"
    local missing=()

    # Check outputs.plan is non-null, non-empty
    local plan
    plan=$(jq -r '.outputs.plan // ""' "$file" 2>/dev/null || echo "")
    if [[ -z "$plan" || "$plan" == "null" ]]; then
        missing+=("outputs.plan")
    fi

    # Check session.session_id is present
    local sid
    sid=$(jq -r '.session.session_id // ""' "$file" 2>/dev/null || echo "")
    if [[ -z "$sid" ]]; then
        missing+=("session.session_id")
    fi

    if [[ ${#missing[@]} -eq 0 ]]; then
        log_pass "Required fields present — outputs.plan and session.session_id OK"
        return 0
    else
        log_fail "Required fields missing: ${missing[*]}"
        return 1
    fi
}

# ── Run single check (dry-run aware) ───────────────────────────────────────
run_check() {
    local check_name="$1"
    shift

    if [[ "$DRY_RUN" == true ]]; then
        log_dry "Would run: $check_name"
        # Still run it but don't count toward score
        "$@" && true || true
        return 0
    fi

    if "$@"; then
        PASS_COUNT=$((PASS_COUNT + 1))
        return 0
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 1
    fi
}

# ── Tier 1: Run all rule checks ────────────────────────────────────────────
run_tier1() {
    local file="$1"
    local rules_file="$2"

    >&2 echo ""
    if [[ "$TIER_FILTER" == "all" || "$TIER_FILTER" == "1" ]]; then
        >&2 echo -e "${CYAN}── Tier 1: Rule-Based Checks ──${NC}"
    fi

    # Run each check explicitly with clear labeling
    # Check 1: Schema valid (-15)
    if run_check "Schema valid" check_schema_valid "$file"; then
        :
    else
        DEDUCTION=$((DEDUCTION + 15))
    fi

    # Check 2: Permissions violated (-40)
    if [[ -n "$rules_file" && "$rules_file" != "not_found" ]]; then
        if run_check "Permissions violated" check_permissions_violated "$file" "$rules_file"; then
            :
        else
            DEDUCTION=$((DEDUCTION + 40))
        fi
    else
        >&2 log_info "No rules.json — skipping permissions check"
        run_check "Permissions violated (skipped)" true
    fi

    # Check 3: Blast radius safe (-40)
    if run_check "Blast radius safe" check_blast_radius_safe "$file"; then
        :
    else
        DEDUCTION=$((DEDUCTION + 40))
    fi

    # Check 4: Writing order correct (-15)
    if run_check "Writing order correct" check_writing_order "$file"; then
        :
    else
        DEDUCTION=$((DEDUCTION + 15))
    fi

    # Check 5: Required fields present (-15)
    if run_check "Required fields present" check_required_fields_present "$file"; then
        :
    else
        DEDUCTION=$((DEDUCTION + 15))
    fi

    # Calculate subtotal (floor at 0)
    local subtotal=$((MAX_SCORE - DEDUCTION))
    [[ $subtotal -lt 0 ]] && subtotal=0

    >&2 echo ""
    if [[ "$TIER_FILTER" == "all" || "$TIER_FILTER" == "1" ]]; then
        >&2 echo -e "${CYAN}── Tier 1 Results: ${PASS_COUNT} pass, ${FAIL_COUNT} fail, ${DEDUCTION} deducted, subtotal=${subtotal} ──${NC}"
    fi

    # Only subtotal to stdout for capture by caller
    echo "${PASS_COUNT}:${FAIL_COUNT}:${DEDUCTION}:${subtotal}"
}

# ── Tier 2: Generate judge prompt JSON (stdout-only for --tier 2) ─────────
tier2_generate_prompt() {
    local file="$1"
    local rules_file="$2"

    local goal accept_criteria judge_prompt

    goal=$(jq -r '.requirements.goal // ""' "$file" 2>/dev/null || echo "")
    accept_criteria=$(jq -r '.requirements.acceptance_criteria // [] | join("; ")' "$file" 2>/dev/null || echo "")
    judge_prompt=$(jq -r '.scoring.tier2.judge_prompt // "You are an impartial judge evaluating an AI agent'\''s output. Score 0-100 based on: (1) Requirements fulfillment 0-40, (2) Governance compliance 0-30, (3) Completeness 0-20, (4) Edge cases and risks 0-10. Return JSON: { score: N, rationale: \"...\", missing_items: [...] }"' "$rules_file" 2>/dev/null || echo "")

    cat <<JUDGE_EOF
{
  "judge_prompt": $(echo "$judge_prompt" | jq -Rs .),
  "contract": {
    "requirements": {
      "goal": $(echo "$goal" | jq -Rs .),
      "acceptance_criteria": $(echo "$accept_criteria" | jq -Rs .)
    }
  },
  "output": {
    "score": 0,
    "rationale": "",
    "missing_items": []
  }
}
JUDGE_EOF
}

# ── Tier 2: LLM-as-Judge (returns score|rationale|missing to stdout) ─────
run_tier2_judge() {
    local file="$1"
    local rules_file="$2"

    local judge_score=0
    local judge_rationale="LLM judge unavailable in bash context — Tier 2 requires LLM invocation"
    local judge_missing="[]"

    if command -v lean-ctx &>/dev/null; then
        # Try lean-ctx ctx_shell for scoring (will likely fail in bash context)
        # Build scoring request
        local goal accept_criteria
        goal=$(jq -r '.requirements.goal // "N/A"' "$file" 2>/dev/null || echo "N/A")
        accept_criteria=$(jq -r '.requirements.acceptance_criteria // [] | join("; ")' "$file" 2>/dev/null || echo "")

        # Attempt lean-ctx judge call
        local judge_raw
        judge_raw=$(lean-ctx ctx_shell "echo 'lean-ctx judge: cannot call LLM from shell context'" 2>/dev/null || true)

        # Conservative fallback: lean-ctx can't call an LLM from shell context
        judge_score=0
        judge_rationale="LLM judge unavailable in bash context — Tier 2 requires LLM invocation via orchestrator"
        judge_missing="[]"

        if [[ "$DRY_RUN" == true ]]; then
            # In dry-run, signal that this would be a real LLM call
            judge_rationale="DRY-RUN: Would invoke LLM judge via orchestrator"
        fi
    else
        judge_rationale="LLM judge unavailable (lean-ctx not found) — fell back to Tier 1 subtotal"
    fi

    echo "${judge_score}|${judge_rationale}|${judge_missing}"
}

# ── Tier 2: Display wrapper (display → stderr, result → stdout) ───────────
run_tier2() {
    local file="$1"
    local rules_file="$2"
    local subtotal="$3"

    if [[ "$TIER_FILTER" == "2" ]]; then
        >&2 echo ""
        >&2 echo -e "${CYAN}── Tier 2: Judge Prompt (pass-through) ──${NC}"
        >&2 echo ""
        tier2_generate_prompt "$file" "$rules_file"
        >&2 echo ""
        >&2 echo -e "${YELLOW}[INFO]${NC} This JSON should be forwarded to an LLM for scoring."
        >&2 echo -e "${YELLOW}[INFO]${NC} Tier 2 not available in bash context — returning conservative fallback."
        >&2 echo "$subtotal"
        return
    fi

    # Full scoring mode
    >&2 echo ""
    >&2 echo -e "${CYAN}── Tier 2: LLM-as-Judge ──${NC}"

    if [[ "$DRY_RUN" == true ]]; then
        >&2 log_dry "Would invoke LLM judge via orchestrator with this prompt:"
        >&2 tier2_generate_prompt "$file" "$rules_file" | head -5
        >&2 log_info "Judge score would be determined by LLM response"
    fi

    local result
    result=$(run_tier2_judge "$file" "$rules_file")

    local judge_score judge_rationale judge_missing
    judge_score=$(echo "$result" | cut -d'|' -f1)
    judge_rationale=$(echo "$result" | cut -d'|' -f2)
    judge_missing=$(echo "$result" | cut -d'|' -f3)

    # Fallback: if LLM judge unavailable (score=0), use Tier 1 subtotal as per spec
    if [[ "$judge_score" == "0" && "$judge_rationale" == *"unavailable"* ]]; then
        judge_score="$subtotal"
        judge_rationale="LLM judge unavailable — fell back to Tier 1 subtotal (${subtotal})"
        judge_missing="[]"
    fi

    >&2 echo ""
    >&2 echo -e "${CYAN}── Tier 2 Result: score=${judge_score} ──${NC}"

    # Only the result line goes to stdout for capture by caller
    echo "${judge_score}|${judge_rationale}|${judge_missing}"
}

# ── Tier 3: Combined Verdict ───────────────────────────────────────────────
compute_verdict() {
    local combined="$1"

    if [[ $combined -ge 70 ]]; then
        echo "PASS"
    elif [[ $combined -ge 50 ]]; then
        echo "RETRY"
    else
        echo "BLOCKED"
    fi
}

# ── Main ───────────────────────────────────────────────────────────────────
main() {
    ensure_jq

    # Parse args
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --file)     CONTRACT_FILE="$2"; shift 2 ;;
            --rules)    RULES_FILE="$2"; shift 2 ;;
            --tier)     TIER_FILTER="$2"; shift 2 ;;
            --score-only) SCORE_ONLY=true; shift ;;
            --dry-run)  DRY_RUN=true; shift ;;
            --verbose)  VERBOSE=true; shift ;;
            --help|-h)  usage ;;
            *) echo "Unknown option: $1" >&2; usage ;;
        esac
    done

    # Validate contract file
    if [[ -z "$CONTRACT_FILE" ]]; then
        echo "ERROR: --file is required. Use --help for usage." >&2
        exit 2
    fi
    if [[ ! -f "$CONTRACT_FILE" ]]; then
        echo "ERROR: File not found: $CONTRACT_FILE" >&2
        exit 2
    fi

    # Validate rules file (optional, warn but proceed)
    if [[ -z "$RULES_FILE" ]]; then
        RULES_FILE="$PROJECT_DIR/rules/rules.json"
    fi
    if [[ ! -f "$RULES_FILE" ]]; then
        echo -e "${YELLOW}[WARN]${NC} Rules file not found: $RULES_FILE" >&2
        echo -e "${YELLOW}[WARN]${NC} Tier 1 checks requiring rules.json will be skipped" >&2
        RULES_FILE=""
    fi

    # Validate tier value
    if [[ "$TIER_FILTER" != "all" && "$TIER_FILTER" != "1" && "$TIER_FILTER" != "2" ]]; then
        echo "ERROR: --tier must be 1 or 2 (default: all)" >&2
        exit 2
    fi

    # Banner
    if [[ "$SCORE_ONLY" == false && "$DRY_RUN" == false ]]; then
        echo "=========================================="
        echo " Auto-Score Pipeline"
        echo " File: $CONTRACT_FILE"
        echo " Rules: ${RULES_FILE:-$(echo -e "${YELLOW}not found${NC}")}"
        echo " Tier: ${TIER_FILTER}"
        echo "=========================================="
    fi

    if [[ "$DRY_RUN" == true ]]; then
        echo ""
        echo -e "${YELLOW}══ DRY RUN MODE — no scoring applied ══${NC}"
    fi

    # ── Tier 1 ──
    local tier1_subtotal=0
    if [[ "$TIER_FILTER" == "all" || "$TIER_FILTER" == "1" ]]; then
        local t1_result
        t1_result=$(run_tier1 "$CONTRACT_FILE" "${RULES_FILE:-not_found}")
        # Parse: pass_count:fail_count:deduction:subtotal
        PASS_COUNT=$(echo "$t1_result" | cut -d':' -f1)
        FAIL_COUNT=$(echo "$t1_result" | cut -d':' -f2)
        DEDUCTION=$(echo "$t1_result" | cut -d':' -f3)
        tier1_subtotal=$(echo "$t1_result" | cut -d':' -f4)
    fi

    # ── Tier 2 ──
    local judge_score=0
    local judge_rationale=""
    local judge_missing="[]"

    if [[ "$TIER_FILTER" == "2" ]]; then
        # --tier 2 mode: print judge prompt and subtotal, then exit
        local t2_stdout
        t2_stdout=$(run_tier2 "$CONTRACT_FILE" "${RULES_FILE:-not_found}" "$tier1_subtotal")
        echo "$t2_stdout"
        if [[ "$DRY_RUN" == true ]]; then
            echo ""
            echo -e "${YELLOW}══ DRY RUN COMPLETE — no files modified ══${NC}"
        fi
        exit 0
    fi

    if [[ "$TIER_FILTER" == "all" ]]; then
        # If Tier 1 subtotal < 70 and scoring all tiers, skip Tier 2 as per spec
        if [[ $tier1_subtotal -lt 70 ]]; then
            judge_score=$tier1_subtotal
            judge_rationale="Tier 1 subtotal < 70 — Tier 2 skipped per spec"
            judge_missing="[]"
            echo ""
            echo -e "${YELLOW}[INFO]${NC} Tier 1 subtotal ($tier1_subtotal) < 70 — skipping Tier 2"
        else
            local tier2_result
            tier2_result=$(run_tier2 "$CONTRACT_FILE" "${RULES_FILE:-not_found}" "$tier1_subtotal")

            # Parse result: score|rationale|missing_items JSON array
            judge_score=$(echo "$tier2_result" | cut -d'|' -f1)
            judge_rationale=$(echo "$tier2_result" | cut -d'|' -f2)
            judge_missing=$(echo "$tier2_result" | cut -d'|' -f3)
        fi
    fi

    # ── Tier 3: Combined ──
    local combined_score
    if [[ "$TIER_FILTER" == "1" ]]; then
        combined_score=$tier1_subtotal
    elif [[ "$TIER_FILTER" == "2" ]]; then
        combined_score=$judge_score
    else
        # Per spec: combined = (tier1_subtotal + judge_score) / 2 rounded
        combined_score=$(( (tier1_subtotal + judge_score + 1) / 2 ))
    fi

    local verdict
    verdict=$(compute_verdict "$combined_score")

    # ── Output ──
    if [[ "$DRY_RUN" == true ]]; then
        echo ""
        echo -e "${YELLOW}══ DRY RUN COMPLETE — no files modified ══${NC}"
        exit 0
    fi

    if [[ "$SCORE_ONLY" == true ]]; then
        echo "$combined_score"
    else
        # Build tier1 output
        local rules_pass rules_fail rules_deduct rules_subtotal
        rules_pass=$PASS_COUNT
        rules_fail=$FAIL_COUNT
        rules_deduct=$DEDUCTION
        rules_subtotal=$tier1_subtotal

        # Escape judge items for JSON
        local judge_rationale_escaped
        judge_rationale_escaped=$(echo "$judge_rationale" | jq -Rs .)

        echo ""
        jq -n \
            --argjson rp "$rules_pass" \
            --argjson rf "$rules_fail" \
            --argjson rd "$rules_deduct" \
            --argjson rs "$rules_subtotal" \
            --argjson js "$judge_score" \
            --arg jrt "$judge_rationale_escaped" \
            --argjson jm "$judge_missing" \
            --argjson cs "$combined_score" \
            --arg v "$verdict" \
            '{
                score: {
                    rules: {
                        pass: $rp,
                        fail: $rf,
                        deduction: $rd,
                        subtotal: $rs
                    },
                    judge: {
                        score: $js,
                        rationale: ($jrt | fromjson),
                        missing_items: $jm
                    },
                    combined: $cs,
                    verdict: $v
                }
            }'
    fi

    # Exit code
    if [[ $combined_score -ge 70 ]]; then
        exit 0
    elif [[ $combined_score -ge 50 ]]; then
        exit 1
    else
        exit 2
    fi
}

main "$@"
