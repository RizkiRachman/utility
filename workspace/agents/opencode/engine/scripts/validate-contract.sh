#!/usr/bin/env bash
# =============================================================================
# validate-contract.sh — Envelope Integrity & Transition Validator
#
# Validates a session/contract.json (or contract.template.json) against:
#   1. JSON validity
#   2. Schema-required field presence (top-level + nested subsections)
#   3. State machine enum validity
#   4. State transition validity (when --prev-state or --rules provided)
#
# Usage:
#   ./scripts/validate-contract.sh [--file path] [--rules path] [--prev-state STATE]
#   ./scripts/validate-contract.sh            # auto-detect session/contract.json → template
#   ./scripts/validate-contract.sh --verbose  # detailed field-level reporting
#   ./scripts/validate-contract.sh --score    # output numeric score for CI
#
# Exit codes:
#   0 = PASS (score ≥ 70)
#   1 = RETRY (score 50-69)
#   2 = BLOCKED (score < 50 or critical errors)
# =============================================================================

set -euo pipefail

# --- Config ----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
CONTRACT_FILE=""
RULES_FILE="$PROJECT_DIR/rules/rules.json"
PREV_STATE=""
VERBOSE=false
SCORE_MODE=false
MAX_DEPTH=2
PASS_COUNT=0
FAIL_COUNT=0
DEDUCTION=0
MAX_SCORE=100
BC_UNAVAILABLE=false
BLOCK_ON_VIOLATION=false

# Check for optional dependencies
command -v bc >/dev/null 2>&1 || { echo "[WARN] bc not available, score gates disabled" >&2; BC_UNAVAILABLE=true; }

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- Help ------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Validate a contract JSON file against schema and transition rules.

Options:
  --file PATH         Contract JSON file to validate (default: auto-detect)
  --rules PATH        Path to rules.json (default: \$PROJECT_DIR/rules/rules.json)
  --prev-state STATE  Expected previous state for transition validation
  --verbose           Show detailed field-level results
  --score             Output numeric score only (for CI/scripts)
  --max-depth N       Max validation depth: 0=minimal, 1=basic, 2=full (default: 2)
  --help              Show this message
EOF
    exit 0
}

# --- Logging functions -----------------------------------------------------
# log_pass/log_fail/log_info come from scripts/lib; log_verbose stays local
# (plain indented text here vs the lib's tagged [VERB] form).
log_verbose() { [[ "$VERBOSE" == true ]] && echo "  $1"; }

# --- Auto-detect contract file ---------------------------------------------
detect_contract_file() {
    local candidates=()
    local br
    br=$(echo session 2>/dev/null || echo "")
    if [[ -n "$br" && "$br" != "HEAD" ]]; then
        candidates+=("$PROJECT_DIR/session/contract.json")
    fi
    candidates+=(
        "$PROJECT_DIR/contract/contract.json"
        "$PROJECT_DIR/contract/contract.template.json"
    )
    for f in "${candidates[@]}"; do
        if [[ -f "$f" ]]; then
            CONTRACT_FILE="$f"
            return 0
        fi
    done
    echo "ERROR: No contract file found. Use --file to specify." >&2
    exit 1
}

# --- Step 0: JSON Schema validation (optional — requires python3 jsonschema) -
check_jsonschema() {
    local file="$1"
    local schema="$PROJECT_DIR/contract/contract.schema.json"
    if [[ ! -f "$schema" ]]; then
        log_verbose "contract.schema.json not found at $schema — skipping schema validation"
        return 0
    fi
    if ! python3 -c "import jsonschema" 2>/dev/null; then
        log_verbose "python3 jsonschema module not installed — skipping schema validation (graceful skip)"
        return 0
    fi
    if python3 -c "
import json, sys
from jsonschema import validators
with open('$schema') as f:
    schema = json.load(f)
with open('$file') as f:
    data = json.load(f)
cls = validators.validator_for(schema)
errors = sorted(cls(schema).iter_errors(data), key=lambda e: list(e.path))
if errors:
    for e in errors[:10]:
        print('  [SCHEMA] ' + '/'.join(str(p) for p in e.path) + ': ' + e.message[:160])
    sys.exit(1)
sys.exit(0)
" 2>&1; then
        log_pass "JSON Schema validation passed (contract.schema.json)"
        return 0
    else
        log_fail "JSON Schema validation failed (see above)"
        return 1
    fi
}

# --- Step 1: JSON validity -------------------------------------------------
check_json_valid() {
    local file="$1"
    if python3 -c "
import json, sys
try:
    with open('$file') as f:
        json.load(f)
    sys.exit(0)
except Exception as e:
    print(str(e))
    sys.exit(1)
"; then
        log_pass "JSON is valid"
        return 0
    else
        log_fail "JSON is INVALID"
        return 1
    fi
}

# --- Step 2: Top-level required fields -------------------------------------
REQUIRED_TOP_LEVEL=(
    "contract_version" "state_machine_version" "state" "session" "requirements"
    "decisions" "governance" "score" "retry" "outputs" "metrics"
    "token_budget" "scope" "validation" "lessons_learned" "audit_log"
)

check_top_level_fields() {
    local file="$1"
    local missing=()
    for field in "${REQUIRED_TOP_LEVEL[@]}"; do
        if ! python3 -c "
import json
with open('$file') as f:
    data = json.load(f)
print('$field' in data)
" 2>/dev/null | grep -q True; then
            missing+=("$field")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        log_pass "All 16 top-level required fields present"
        return 0
    else
        log_fail "Missing top-level fields: ${missing[*]}"
        return 1
    fi
}

# --- Step 3: Validate state enum ------------------------------------------
VALID_STATES=("INIT" "PLAN" "PLAN_SCORED" "EXECUTE" "EXECUTE_SCORED" "REVIEW" "REVIEW_SCORED" "COMPLETE" "BLOCKED")

check_state_enum() {
    local file="$1"
    local state
    state=$(python3 -c "
import json
with open('$file') as f:
    print(json.load(f).get('state', 'MISSING'))
" 2>/dev/null)

    if [[ "$state" == "MISSING" ]]; then
        log_fail "'state' field is missing"
        return 1
    fi

    for valid in "${VALID_STATES[@]}"; do
        if [[ "$state" == "$valid" ]]; then
            log_pass "State '$state' is valid enum value"
            return 0
        fi
    done

    log_fail "State '$state' is NOT a valid enum value (${VALID_STATES[*]})"
    return 1
}

# --- Step 4: Nested required fields (per schema) ---------------------------
check_nested_fields() {
    local file="$1"
    local nested_checks=(
        "session:task_id"
        "session:session_id"
        "session:created_at"
        "session:archived_at"
        "requirements:goal"
        "requirements:acceptance_criteria"
        "requirements:constraints"
        "decisions:approved_architecture"
        "decisions:coding_standard"
        "decisions:rejected_approaches"
        "decisions:adr_log"
        "decisions:ddd_performed"
        "governance:active_agent"
        "governance:mode"
        "governance:applicable_skills"
        "governance:rules_references"
        "governance:current_guidance"
        "governance:permissions"
        "governance:previous_blockers"
        "score:rules"
        "score:judge"
        "score:combined"
        "score:verdict"
        "retry:current_phase"
        "retry:attempt"
        "retry:max_attempts"
        "retry:score_threshold"
        "retry:escalation_threshold"
        "retry:phase_issues"
        "retry:escalation_trace"
        "outputs:plan"
        "outputs:architecture"
        "outputs:code_changes"
        "outputs:test_results"
        "outputs:agent_reports"
        "outputs:score_summary"
        "outputs:debt_ledger"
        "decisions:confidence_scores"
        "metrics:cost_tokens"
        "metrics:elapsed_ms"
        "metrics:agents_used"
        "metrics:phases_completed"
        "metrics:phase_durations"
        "token_budget:max_per_session"
        "token_budget:warning_threshold"
        "token_budget:hard_limit"
        "token_budget:max_per_phase"
        "token_budget:max_per_subagent_call"
        "token_budget:current_session_usage"
        "token_budget:phase_usage"
        "scope:included"
        "scope:excluded"
        "scope:boundary"
        "scope:parallel_eligible"
        "scope:max_parallel_agents"
        "scope:shard_id"
        "scope:parallel_instances"
        "validation:block_on"
        "validation:rule_overrides"
        "validation:build_verified"
        "validation/block_on:max_test_failures"
        "validation/block_on:max_score_drop"
        "validation/block_on:max_compile_errors"
    )

    local missing=()
    for check in "${nested_checks[@]}"; do
        IFS=':' read -r parent field <<< "$check"
        # Handle nested paths like validation/block_on
        if [[ "$parent" == */* ]]; then
            local parent_key="${parent%/*}"
            local sub_key="${parent#*/}"
            if ! python3 -c "
import json
with open('$file') as f:
    data = json.load(f)
try:
    d = data
    for k in '${parent_key}','${sub_key}':
        d = d[k]
    print('${field}' in d)
except:
    print('False')
" 2>/dev/null | grep -q True; then
                missing+=("$parent.$field")
            fi
        else
            if ! python3 -c "
import json
with open('$file') as f:
    data = json.load(f)
try:
    print('${field}' in data['${parent}'])
except:
    print('False')
" 2>/dev/null | grep -q True; then
                missing+=("$parent.$field")
            fi
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        log_pass "All 60+ nested required fields present"
        return 0
    else
        log_fail "Missing nested fields (${#missing[@]}): ${missing[*]}"
        return 1
    fi
}

# --- Step 5: Content quality checks (Tier 1 semantic validation) -----------
check_content_quality() {
    local file="$1"

    if python3 -c "
import json, sys

with open('$file') as f:
    data = json.load(f)

fails = []
state = data.get('state', 'INIT')
score = data.get('score', {})
outputs = data.get('outputs', {})
audit = data.get('audit_log', [])
scope = data.get('scope', {})
decisions = data.get('decisions', {})
validation = data.get('validation', {})

state_rank = ['INIT', 'PLAN', 'PLAN_SCORED', 'EXECUTE', 'EXECUTE_SCORED', 'REVIEW', 'REVIEW_SCORED', 'COMPLETE', 'BLOCKED']
try:
    si = state_rank.index(state)
except ValueError:
    si = 0

# 1. If state beyond INIT, score should not be all zeros/INIT
if si >= 1:
    combined = score.get('combined', 0)
    verdict = score.get('verdict', 'INIT')
    if combined == 0 and verdict == 'INIT':
        fails.append('State %s but score still 0/INIT' % state)

# 2. If PLAN_SCORED+, outputs.plan should not be null
if si >= 2:
    plan = outputs.get('plan')
    if plan is None or plan == '':
        fails.append('State %s but outputs.plan null/empty' % state)

# 3. If REVIEW_SCORED+, outputs.architecture should not be null
if si >= 6:
    arch = outputs.get('architecture')
    if arch is None:
        fails.append('State %s but outputs.architecture null' % state)

# 4. If EXECUTE_SCORED+, outputs.code_changes should not be empty
if si >= 4:
    changes = outputs.get('code_changes', [])
    if len(changes) == 0:
        fails.append('State %s but outputs.code_changes empty' % state)

# 5. If verdict is PASS, combined score should be >= 70
if score.get('verdict') == 'PASS' and score.get('combined', 0) < 70:
    fails.append('score.verdict PASS but combined=%d < 70' % score.get('combined', 0))

# 6. If state beyond INIT, audit_log should not be empty
if si >= 1 and len(audit) == 0:
    fails.append('State %s but audit_log empty' % state)

# 6a. Audit log trim: flag if >100 entries or >10KB content
if len(audit) > 100:
    fails.append('audit_log has %d entries (>100) — consider trimming' % len(audit))
if len(str(audit)) > 10240:
    fails.append('audit_log content is %d bytes (>10KB) — consider trimming' % len(str(audit)))

# 7. SDD gate: if scope.included has >3 items, flag SDD
incl = scope.get('included', [])
if len(incl) > 3:
    fails.append('scope.included has %d items (>3) — SDD should trigger' % len(incl))

# 8. DDD: if PLAN_SCORED+, decisions.ddd_performed should be true
if si >= 2:
    ddd = decisions.get('ddd_performed', False)
    if not ddd:
        fails.append('State %s but decisions.ddd_performed false — DDD should have run' % state)

# 9. Build verify: if REVIEW_SCORED+, validation.build_verified should be true
if si >= 6:
    bv = validation.get('build_verified', False)
    if not bv:
        fails.append('State %s but validation.build_verified false — build verify should have run' % state)

# 10. Recurring retry tracking: check escalation_trace for repeated patterns
retry_data = data.get('retry', {})
trace = retry_data.get('escalation_trace', [])
if len(trace) >= 2:
    issue_counts = {}
    for entry in trace:
        if isinstance(entry, dict):
            # Object entries: extract from 'issues' key or use stringified entry
            issues = entry.get('issues', [entry.get('reason', str(entry))[:80]])
            for issue in (issues if isinstance(issues, list) else [str(issues)[:80]]):
                key = str(issue)[:80]
                issue_counts[key] = issue_counts.get(key, 0) + 1
        elif isinstance(entry, str):
            issue_counts[entry[:80]] = issue_counts.get(entry[:80], 0) + 1
    recurring = {k: v for k, v in issue_counts.items() if v >= 2}
    if recurring:
        for issue, count in recurring.items():
            fails.append('Recurring retry issue (%dx): %s' % (count, issue[:60]))

# 11. Partial credit: when BLOCKED, note what passed
if state == 'BLOCKED':
    # Report checks that DID pass before failing
    passed = []
    if si >= 1 and score.get('combined', 0) > 0:
        passed.append('score recorded (combined=%d)' % score.get('combined'))
    if si >= 2 and outputs.get('plan'):
        passed.append('plan exists')
    if len(audit) > 0:
        passed.append('%d audit entries' % len(audit))
    if passed:
        print('  [PARTIAL] BLOCKED state — %d checks passed: %s' % (len(passed), '; '.join(passed)))

if len(fails) > 0:
    for f in fails:
        print('  [CONTENT] ' + f)
    sys.exit(1)
sys.exit(0)
" 2>&1; then
        log_pass "Content quality checks passed"
        return 0
    else
        log_fail "Content quality issues detected (see above)"
        return 1
    fi
}

# --- Step 6a: Field-level access control check ----------------------------
check_field_access() {
    local file="$1"

    if python3 -c "
import json, sys

with open('$file') as f:
    data = json.load(f)

gov = data.get('governance', {})
perms = gov.get('permissions', {})
ro = perms.get('read_only_fields', [])
wo = perms.get('writeable_fields', [])

# Check no overlap
overlap = [f for f in ro if f in wo]
if overlap:
    print('  [CONTENT] Field access overlap (read-only and writeable both contain): ' + ', '.join(overlap))

# Check all listed fields exist as top-level keys
top_keys = set(data.keys())
all_listed = set(ro + wo)
missing = [f for f in all_listed if f not in top_keys]
if missing:
    print('  [CONTENT] Field access references non-existent top-level keys: ' + ', '.join(missing))

if overlap or missing:
    sys.exit(1)
sys.exit(0)
" 2>&1; then
        log_pass "Field-level access control valid"
        return 0
    else
        log_fail "Field-level access control issues detected (see above)"
        return 1
    fi
}

# --- Step 6b: Scope consistency checks (jq-based) ---------------------------
check_scope_consistency() {
    local file="$1"
    local issues=0

    # Check 1: parallel_eligible=true -> max_parallel_agents >= 1
    if ! jq -e '.scope | if .parallel_eligible then (.max_parallel_agents | type == "number" and . >= 1) else true end' "$file" >/dev/null 2>&1; then
        local mpa
        mpa=$(jq -r '.scope.max_parallel_agents // "missing"' "$file")
        log_fail "parallel_eligible=true but max_parallel_agents=$mpa (must be >= 1)"
        issues=$((issues + 1))
    fi

    # Check 2: included / excluded overlap
    local overlap
    overlap=$(jq -r '.scope.included[] as $i | .scope.excluded[] | select(. == $i)' "$file" 2>/dev/null | head -5 | tr '\n' ',')
    if [[ -n "$overlap" ]]; then
        log_fail "scope.included and scope.excluded overlap: $overlap"
        issues=$((issues + 1))
    fi

    # Check 3: shard_id implies parallel_eligible
    local shard_id
    shard_id=$(jq -r '.scope.shard_id // ""' "$file")
    if [[ -n "$shard_id" ]]; then
        local pe
        pe=$(jq -r '.scope.parallel_eligible // false' "$file")
        if [[ "$pe" != "true" ]]; then
            log_fail "shard_id=\"$shard_id\" set but parallel_eligible=false"
            issues=$((issues + 1))
        fi
    fi

    # Check 4: parallel_instances non-empty when parallel_eligible=true
    local pe
    pe=$(jq -r '.scope.parallel_eligible // false' "$file")
    if [[ "$pe" == "true" ]]; then
        local inst_count
        inst_count=$(jq -r '.scope.parallel_instances | length' "$file")
        if [[ "$inst_count" -eq 0 ]]; then
            log_fail "parallel_eligible=true but parallel_instances empty"
            issues=$((issues + 1))
        fi
    fi

    # Check 5: shard_id in parallel_instances
    if [[ -n "$shard_id" && "$pe" == "true" ]]; then
        local found
        found=$(jq -r --arg sid "$shard_id" '.scope.parallel_instances | index($sid)' "$file")
        if [[ "$found" == "null" ]]; then
            log_fail "shard_id=\"$shard_id\" not in parallel_instances"
            issues=$((issues + 1))
        fi
    fi

    if [[ $issues -eq 0 ]]; then
        log_pass "Scope consistency checks passed"
        return 0
    else
        log_fail "Scope consistency: $issues issue(s) detected"
        return 1
    fi
}

# --- Step 6c: Timeout enforcement checks -----------------------------------
check_timeout_enforcement() {
    local file="$1"
    local rules_file="$2"
    if [[ ! -f "$rules_file" ]]; then
        log_verbose "No rules file, skipping timeout enforcement"
        return 0
    fi
    local scoring_timeout delegation_timeout elapsed issues=0
    scoring_timeout=$(jq -r '.scoring.timeout_ms // 30000' "$rules_file" 2>/dev/null)
    delegation_timeout=$(jq -r '.agent_watchdog.delegation_timeout_ms // 120000' "$rules_file" 2>/dev/null)
    elapsed=$(jq -r '.metrics.elapsed_ms // 0' "$file")
    if [[ "$elapsed" -gt 0 && "$elapsed" -gt "$scoring_timeout" ]]; then
        log_fail "metrics.elapsed_ms ($elapsed ms) exceeds scoring.timeout_ms ($scoring_timeout ms)"
        issues=$((issues + 1))
    fi
    if [[ "$delegation_timeout" -gt 0 ]]; then
        log_verbose "delegation_timeout_ms configured: $delegation_timeout ms"
    fi
    if [[ $issues -eq 0 ]]; then
        log_pass "Timeout enforcement checks passed"
        return 0
    else
        log_fail "Timeout enforcement: $issues issue(s) detected"
        return 1
    fi
}
# --- Step 6d: Parallel deadlock detection config check ---------------------
check_deadlock_config() {
    local file="$1"
    local rules_file="$2"
    if [[ ! -f "$rules_file" ]]; then
        log_verbose "No rules file, skipping deadlock config check"
        return 0
    fi
    local deadlock_enabled parallel_eligible issues=0 max_cycles script
    deadlock_enabled=$(jq -r '.agent_watchdog.parallel_deadlock_detection.enabled // false' "$rules_file")
    parallel_eligible=$(jq -r '.scope.parallel_eligible // false' "$file")
    if [[ "$deadlock_enabled" == "true" && "$parallel_eligible" == "false" ]]; then
        log_fail "parallel_deadlock_detection enabled in rules but scope.parallel_eligible=false in contract"
        issues=$((issues + 1))
    fi
    if [[ "$deadlock_enabled" == "true" ]]; then
        max_cycles=$(jq -r '.agent_watchdog.parallel_deadlock_detection.max_wait_cycles // 0' "$rules_file")
        script=$(jq -r '.agent_watchdog.parallel_deadlock_detection.resolution // ""' "$rules_file")
        if [[ "$max_cycles" -eq 0 ]]; then
            log_fail "parallel_deadlock_detection enabled but max_wait_cycles=0"
            issues=$((issues + 1))
        fi
        if [[ -z "$script" ]]; then
            log_fail "parallel_deadlock_detection enabled but no resolution strategy defined"
            issues=$((issues + 1))
        fi
    fi
    if [[ $issues -eq 0 ]]; then
        log_pass "Parallel deadlock detection config valid"
        return 0
    else
        log_fail "Deadlock detection config: $issues issue(s) detected"
        return 1
    fi
}
TRANSITIONS_FILE=$(python3 -c "
import json, sys
with open('$RULES_FILE') as f:
    rules = json.load(f)
trans = rules.get('state_machine', {}).get('transitions', [])
for t in trans:
    print(f\"{t.get('from','?')}->{t.get('to','?')}\")
" 2>/dev/null) || TRANSITIONS_FILE=""

check_transition() {
    local contract_file="$1"
    local rules_file="$2"
    local current_state
    current_state=$(python3 -c "
import json
with open('$contract_file') as f:
    print(json.load(f).get('state', ''))
")

    if [[ -z "$PREV_STATE" ]]; then
        log_verbose "No --prev-state provided, skipping transition validation"
        return 0
    fi

    if [[ "$PREV_STATE" == "$current_state" ]]; then
        log_verbose "State unchanged ($PREV_STATE → $current_state), no transition needed"
        return 0
    fi

    # Check if transition is valid per rules.json
    local valid=false
    # rules.json uses wildcard "*" for any-to-any (or specific transitions)
    while IFS= read -r rule_trans; do
        local from="${rule_trans%%->*}"
        local to="${rule_trans##*->}"
        if [[ ("$from" == "$PREV_STATE" || "$from" == "*") && ("$to" == "$current_state" || "$to" == "*") ]]; then
            valid=true
            break
        fi
    done <<< "$TRANSITIONS_FILE"

    if [[ "$valid" != true ]]; then
        log_fail "Transition '$PREV_STATE → $current_state' is NOT in rules.json allowed transitions"
        return 1
    fi

    # Check score threshold for this transition (if defined in rules)
    local threshold
    threshold=$(jq -r --arg from "$PREV_STATE" --arg to "$current_state" '
        [.state_machine.transitions[]
        | select(.from == $from and .to == $to)
        | .require_score // null][0]
    ' "$rules_file" 2>/dev/null || echo "null")

    if [[ "$threshold" != "null" && -n "$threshold" ]]; then
        if [[ "$BC_UNAVAILABLE" == true ]]; then
            log_fail "Score gate cannot be checked — bc not available"
            return 1
        fi
        local actual_score
        actual_score=$(python3 -c "
import json
with open('$contract_file') as f:
    print(json.load(f).get('score', {}).get('combined', 0))
")
        if (( $(echo "$actual_score < $threshold" | bc -l) )); then
            log_fail "Score gate — $PREV_STATE → $current_state requires score ≥ $threshold, got $actual_score"
            return 1
        fi
    fi

    log_pass "Transition '$PREV_STATE → $current_state' is valid per rules.json"
    return 0
}

# --- Step 7b: Score gate validation (independent of --prev-state) ----------
check_score_gate() {
    local contract_file="$1"

    local current_state new_state
    current_state=$(jq -r '.state // "unknown"' "$contract_file")
    new_state=$(jq -r '.governance.target_state // ""' "$contract_file")

    # If no target_state, can't validate transition
    if [[ "$new_state" == "null" || -z "$new_state" ]]; then
        log_verbose "No governance.target_state set, skipping score gate validation"
        return 0
    fi

    # Read rules for this transition
    local transition_data
    transition_data=$(jq -c --arg from "$current_state" --arg to "$new_state" '
        .state_machine.transitions[]
        | select(.from == $from and .to == $to)
    ' "$RULES_FILE" 2>/dev/null || echo "null")

    if [[ "$transition_data" == "null" ]]; then
        log_fail "No matching transition rule for $current_state → $new_state"
        return 1
    fi

    local require_score
    require_score=$(echo "$transition_data" | jq -r '.require_score // null')

    if [[ "$require_score" != "null" ]]; then
        if [[ "$BC_UNAVAILABLE" == true ]]; then
            log_fail "Score gate cannot be checked — bc not available"
            return 1
        fi
        local actual_score
        actual_score=$(jq -r '.score.combined // 0' "$contract_file")
        if (( $(echo "$actual_score < $require_score" | bc -l) )); then
            log_fail "Score gate — $current_state → $new_state requires score ≥ $require_score, got $actual_score"
            return 1
        fi
        log_pass "Score gate — $current_state → $new_state (score $actual_score ≥ $require_score)"
    fi
    return 0
}

# --- Step 7a: Security review trigger (F-12) ---------------------------------
check_security_trigger() {
    local file="$1"
    local rules_file="$2"
    # Keywords sourced from rules.json security_trigger (fallback list if rules missing)
    local keywords=""
    if [[ -f "$rules_file" ]]; then
        keywords=$(jq -r '.enforcement.cross_model_review.security_trigger.keywords[]?' "$rules_file" 2>/dev/null | tr '\n' ' ')
    fi
    [[ -z "$keywords" ]] && keywords="password secret token apikey api_key private_key jwt oauth crypto"
    local trigger_hit=""
    for kw in $keywords; do
        if jq -e --arg kw "$kw" '[(.requirements | tostring), (.outputs.code_changes | tostring)] | join(" ") | ascii_downcase | test($kw)' "$file" >/dev/null 2>&1; then
            trigger_hit="$kw"
            break
        fi
    done
    if [[ -z "$trigger_hit" ]]; then
        log_verbose "No security-trigger keywords in requirements/outputs.code_changes"
        return 0
    fi
    local used
    used=$(jq -r '[.metrics.agents_used[]?] | join(",")' "$file" 2>/dev/null)
    if [[ ",${used}," == *",security-engineer,"* ]]; then
        log_pass "Security trigger ('$trigger_hit') satisfied — security-engineer in metrics.agents_used"
        return 0
    fi
    log_fail "Security trigger: contract references '$trigger_hit' (auth/secrets/credentials/config/crypto) but metrics.agents_used has no security-engineer"
    return 1
}

# --- Step 7b: block_on threshold enforcement (F-13) -------------------------
check_block_on() {
    local file="$1"
    local violations=0
    # max_test_failures vs outputs.test_results (fail/failed/failed_count)
    local test_failures max_test_failures
    max_test_failures=$(jq -r '.validation.block_on.max_test_failures // empty' "$file" 2>/dev/null)
    if [[ -n "$max_test_failures" ]]; then
        test_failures=$(jq -r '.outputs.test_results.fail // .outputs.test_results.failed // .outputs.test_results.failed_count // 0' "$file" 2>/dev/null)
        if [[ "$test_failures" -gt "$max_test_failures" ]] 2>/dev/null; then
            log_fail "block_on exceeded: test failures ($test_failures) > max_test_failures ($max_test_failures)"
            violations=$((violations + 1))
        fi
    fi
    # max_score_drop / max_compile_errors: the contract schema carries no
    # previous-score or compile-error counter — those two criteria are enforced
    # by the orchestrator's Verify loop (see doc/workflow/04-scoring.md D2).
    if [[ $violations -eq 0 ]]; then
        log_verbose "block_on thresholds satisfied (or not computable from contract)"
        return 0
    fi
    return 1
}

# --- Scoring ---------------------------------------------------------------
compute_score() {
    local total_checks=$((PASS_COUNT + FAIL_COUNT))
    if [[ $total_checks -eq 0 ]]; then
        # This occurs when no checks ran at all (e.g., --score mode with --max-depth=0
        # before any checks are registered). Score 0 is safer than a crash.
        echo "0"
        return
    fi

    # Start at 100, deduct for failures
    local raw_score=$((MAX_SCORE - DEDUCTION))
    if [[ $raw_score -lt 0 ]]; then
        raw_score=0
    fi
    echo "$raw_score"
}

# --- Check wrapper (suppress non-score output in --score mode) -----------
run_check() {
    if [[ "$SCORE_MODE" == true ]]; then
        "$@" >&2
    else
        "$@"
    fi
}

# --- Main ------------------------------------------------------------------
main() {
    # Parse args
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --file) CONTRACT_FILE="$2"; shift 2 ;;
            --rules) RULES_FILE="$2"; shift 2 ;;
            --prev-state) PREV_STATE="$2"; shift 2 ;;
            --verbose) VERBOSE=true; shift ;;
            --score) SCORE_MODE=true; shift ;;
            --max-depth) MAX_DEPTH="$2"; shift 2 ;;
            --help|-h) usage ;;
            *) echo "Unknown option: $1"; usage ;;
        esac
    done

    # Auto-detect contract file if not specified
    if [[ -z "$CONTRACT_FILE" ]]; then
        detect_contract_file
    fi

    if [[ ! -f "$CONTRACT_FILE" ]]; then
        echo "ERROR: File not found: $CONTRACT_FILE" >&2
        exit 2
    fi

    if [[ ! -f "$RULES_FILE" ]]; then
        echo "WARNING: Rules file not found: $RULES_FILE (transition validation disabled)" >&2
    fi

    if [[ "$SCORE_MODE" == false ]]; then
        echo "=========================================="
        echo " Contract Validation Report"
        echo " File: $CONTRACT_FILE"
        echo "=========================================="
        echo ""
    fi

    # Step 0: JSON Schema validation (graceful skip when jsonschema unavailable)
    if run_check check_jsonschema "$CONTRACT_FILE"; then
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        DEDUCTION=$((DEDUCTION + 15))
    fi

    # Step 1: JSON validity
    if ! run_check check_json_valid "$CONTRACT_FILE"; then
        if [[ "$SCORE_MODE" == false ]]; then
            echo ""
            echo "BLOCKED: Invalid JSON"
        fi
        exit 2
    fi
    PASS_COUNT=$((PASS_COUNT + 1))

    # Step 1.5: State field critical check (hard block — contract is meaningless without valid state)
    STATE_VALUE=$(jq -r '.state // ""' "$CONTRACT_FILE" 2>/dev/null)

    if [[ -z "$STATE_VALUE" ]]; then
        if [[ "$SCORE_MODE" == false ]]; then
            echo ""
            echo "BLOCKED: Missing required 'state' field"
        fi
        exit 2
    fi

    VALID_STATES=("INIT" "PLAN" "PLAN_SCORED" "EXECUTE" "EXECUTE_SCORED" "REVIEW" "REVIEW_SCORED" "COMPLETE" "BLOCKED")
    STATE_FOUND=false
    for vs in "${VALID_STATES[@]}"; do
        if [[ "$STATE_VALUE" == "$vs" ]]; then
            STATE_FOUND=true
            break
        fi
    done

    if [[ "$STATE_FOUND" == false ]]; then
        if [[ "$SCORE_MODE" == false ]]; then
            echo ""
            echo "BLOCKED: Invalid state enum value '$STATE_VALUE'"
        fi
        exit 2
    fi

    # Step 2: Top-level fields
    if run_check check_top_level_fields "$CONTRACT_FILE"; then
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        DEDUCTION=$((DEDUCTION + 15))
    fi

    # Step 3: State enum (already hard-blocked above, but still checked for scoring consistency)
    if run_check check_state_enum "$CONTRACT_FILE"; then
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        DEDUCTION=$((DEDUCTION + 15))
    fi

    # Step 3b: Score gate validation (only with --score flag)
    if [[ "$SCORE_MODE" == true && -f "$RULES_FILE" ]]; then
        if run_check check_score_gate "$CONTRACT_FILE"; then
            PASS_COUNT=$((PASS_COUNT + 1))
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
            DEDUCTION=$((DEDUCTION + 20))
        fi
    fi

    # Step 4: Nested fields (depth >= 1)
    if [[ $MAX_DEPTH -ge 1 ]]; then
        if run_check check_nested_fields "$CONTRACT_FILE"; then
            PASS_COUNT=$((PASS_COUNT + 1))
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
            DEDUCTION=$((DEDUCTION + 15))
        fi
    fi

    # Steps 5-6d: Content quality, access control, scope, enforcement (depth >= 2)
    if [[ $MAX_DEPTH -ge 2 ]]; then
        # Step 5: Content quality checks
        if run_check check_content_quality "$CONTRACT_FILE"; then
            PASS_COUNT=$((PASS_COUNT + 1))
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
            DEDUCTION=$((DEDUCTION + 20))
        fi

        # Step 6: Field-level access control
        if run_check check_field_access "$CONTRACT_FILE"; then
            PASS_COUNT=$((PASS_COUNT + 1))
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
            DEDUCTION=$((DEDUCTION + 15))
        fi

        # Step 6b: Scope consistency
        if run_check check_scope_consistency "$CONTRACT_FILE"; then
            PASS_COUNT=$((PASS_COUNT + 1))
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
            DEDUCTION=$((DEDUCTION + 15))
        fi

        # Step 6c: Timeout enforcement
        if run_check check_timeout_enforcement "$CONTRACT_FILE" "$RULES_FILE"; then
            PASS_COUNT=$((PASS_COUNT + 1))
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
            DEDUCTION=$((DEDUCTION + 15))
        fi

        # Step 6d: Parallel deadlock detection config
        if run_check check_deadlock_config "$CONTRACT_FILE" "$RULES_FILE"; then
            PASS_COUNT=$((PASS_COUNT + 1))
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
            DEDUCTION=$((DEDUCTION + 15))
        fi

        # Step 6e (GAP-1): Architecture drift detection
        if [[ -x "$SCRIPT_DIR/check-architecture-drift.sh" ]]; then
            if "$SCRIPT_DIR/check-architecture-drift.sh" --file "$CONTRACT_FILE" 2>/dev/null; then
                PASS_COUNT=$((PASS_COUNT + 1))
            else
                FAIL_COUNT=$((FAIL_COUNT + 1))
                DEDUCTION=$((DEDUCTION + 15))
            fi
        fi

        # Step 6f (GAP-3): Writing order validation (file-level)
        if [[ -x "$SCRIPT_DIR/check-writing-order.sh" ]]; then
            if "$SCRIPT_DIR/check-writing-order.sh" --file "$CONTRACT_FILE" 2>/dev/null; then
                PASS_COUNT=$((PASS_COUNT + 1))
            else
                FAIL_COUNT=$((FAIL_COUNT + 1))
                DEDUCTION=$((DEDUCTION + 15))
            fi
        fi

        # Step 6g (F-12): Security review trigger — hard gate.
        # If requirements/outputs.code_changes reference auth/secrets/credentials/config/crypto
        # surfaces, @security-engineer must appear in metrics.agents_used.
        if ! run_check check_security_trigger "$CONTRACT_FILE" "$RULES_FILE"; then
            if [[ "$SCORE_MODE" == false ]]; then
                echo ""
                echo "BLOCKED: security-sensitive changes require @security-engineer review (metrics.agents_used)"
            fi
            exit 2
        fi
        PASS_COUNT=$((PASS_COUNT + 1))
    fi

    # Step 7: Transition (conditional)
    if [[ -n "$PREV_STATE" ]]; then
        if run_check check_transition "$CONTRACT_FILE" "$RULES_FILE"; then
            PASS_COUNT=$((PASS_COUNT + 1))
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
            DEDUCTION=$((DEDUCTION + 20))
        fi
    fi

    # Step 7b (F-13): block_on enforcement — read contract validation.block_on,
    # fail with exit 1 when a threshold is exceeded (regardless of score).
    if run_check check_block_on "$CONTRACT_FILE"; then
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        DEDUCTION=$((DEDUCTION + 20))
        BLOCK_ON_VIOLATION=true
    fi

    # Compute score
    local score
    score=$(compute_score)

    if [[ "$SCORE_MODE" == false ]]; then
        echo ""
        echo "------------------------------------------"
        echo " Results: $PASS_COUNT passed, $FAIL_COUNT failed"
        echo " Deduction: $DEDUCTION points"
        echo " Score: $score/100"
        echo "------------------------------------------"
    fi

    if [[ "$SCORE_MODE" == true ]]; then
        # Suppress all non-score output in score mode
        echo "$score"
    fi

    # F-13: block_on threshold exceeded forces a failing exit (exit 1) even
    # when the computed score would otherwise pass.
    if [[ "$BLOCK_ON_VIOLATION" == true && $score -ge 70 ]]; then
        if [[ "$SCORE_MODE" == false ]]; then
            echo -e "${YELLOW}VERDICT: FAIL — validation.block_on threshold exceeded${NC}"
        fi
        exit 1
    fi

    # Exit code
    if [[ $score -ge 70 ]]; then
        if [[ "$SCORE_MODE" == false ]]; then
            echo -e "${GREEN}VERDICT: PASS${NC}"
        fi
        exit 0
    elif [[ $score -ge 50 ]]; then
        if [[ "$SCORE_MODE" == false ]]; then
            echo -e "${YELLOW}VERDICT: RETRY${NC}"
        fi
        exit 1
    else
        if [[ "$SCORE_MODE" == false ]]; then
            echo -e "${RED}VERDICT: BLOCKED${NC}"
        fi
        exit 2
    fi
}

main "$@"
