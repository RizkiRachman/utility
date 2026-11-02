#!/usr/bin/env bash
# decision-journal.sh — Auto-persist decisions to the decision journal (G29)
# Reads a contract JSON file, extracts decisions (adr_log entries,
# confidence_scores), and persists them to lean-ctx ctx_knowledge for
# cross-session learning. Also formats decision entries for journal storage.
#
# Usage:
#   scripts/decision-journal.sh --file contract.json list
#   scripts/decision-journal.sh --file contract.json persist
#   scripts/decision-journal.sh --file contract.json add --title "..." --decision "..." [options]
#   scripts/decision-journal.sh --file contract.json score --title "..." --score 4 [options]
#   scripts/decision-journal.sh --file contract.json feedback --decision "<id or ref>" --verdict "<pass|fail|retry>" [options]
#   scripts/decision-journal.sh --file contract.json --help
#
# Commands:
#   list          List all decisions in the contract as a table
#   persist       Persist decisions to lean-ctx ctx_knowledge
#   add           Add a new ADR entry to the contract
#   score         Add a confidence score for a previous decision
#   feedback      Append a reviewer verdict to the feedback history file
#                 (rules.json → .feedback.feedback_loop.store_in)
#
# Add sub-arguments:
#   --title TEXT          Short title of the decision (required)
#   --decision TEXT       What was decided (required)
#   --context TEXT        Why this decision was needed
#   --alternatives TEXT   Rejected alternatives
#   --confidence 1-5      Confidence level (default: 3)
#
# Score sub-arguments:
#   --title TEXT          Title of the decision to score (required)
#   --score 1-5           Confidence score (required)
#   --rationale TEXT      Why this confidence level
#
# Feedback sub-arguments:
#   --decision TEXT       Decision id or reference being reviewed (required)
#   --verdict VERDICT     pass | fail | retry (required)
#   --reviewer NAME       Reviewer name (optional)
#   --notes TEXT          Free-form review notes (optional)
#
# Exit codes:
#   0 — Success
#   1 — Partial success (e.g., some decisions failed to persist)
#   2 — Error (missing deps, file not found, invalid JSON)
#
# Depends on: jq (required), python3 (optional, for slug generation)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Shared logging/counters/store_in helpers (scripts/lib)
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Defaults ────────────────────────────────────────────────────────────────
CONTRACT_FILE=""
DRY_RUN=false
VERBOSE=false
HELP=false

# Subcommand defaults
COMMAND=""
TITLE=""
DECISION_TEXT=""
CONTEXT=""
ALTERNATIVES=""
CONFIDENCE=3
SCORE=3
RATIONALE=""

# Feedback subcommand defaults
FEEDBACK_DECISION=""
FEEDBACK_VERDICT=""
REVIEWER=""
NOTES=""

# ── Usage ───────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] <COMMAND> [SUB-ARGS]

Auto-persist decisions to the decision journal for cross-session learning.

Options:
  --file PATH      Contract JSON file (required for all commands)
  --dry-run        Preview changes without modifying anything
  --verbose        Show detailed output
  --help           Show this help message and exit

Commands:
  list          List all decisions in the contract as a table
  persist       Persist decisions to lean-ctx ctx_knowledge
  add           Add a new ADR entry to the contract
  score         Add a confidence score for a previous decision
  feedback      Append a reviewer verdict to the feedback history file

Add sub-arguments:
  --title TEXT          Short title of the decision (required)
  --decision TEXT       What was decided (required)
  --context TEXT        Why this decision was needed
  --alternatives TEXT   Rejected alternatives
  --confidence 1-5      Confidence level (default: 3)

Score sub-arguments:
  --title TEXT          Title of the decision to score (required)
  --score 1-5           Confidence score (required)
  --rationale TEXT      Why this confidence level

Feedback sub-arguments:
  --decision TEXT       Decision id or reference being reviewed (required)
  --verdict VERDICT     pass | fail | retry (required)
  --reviewer NAME       Reviewer name (optional)
  --notes TEXT          Free-form review notes (optional)

Config:
  ADR format stored in contract.decisions.adr_log[]
  Scores stored in contract.decisions.confidence_scores[]
  Lean-ctx keys: decision/<title-slug>
  Feedback history: rules.json → .feedback.feedback_loop.store_in
    (default session/feedback-history.json, shape {"history": [...]})

Examples:
  $(basename "$0") --file contract.json list
  $(basename "$0") --file contract.json persist --verbose
  $(basename "$0") --file contract.json add --title "Use PostgreSQL" \\
      --decision "Adopt PostgreSQL 16 as primary DB" \\
      --context "Need strong consistency and ACID compliance" \\
      --alternatives "MongoDB, MySQL, SQLite" --confidence 4
  $(basename "$0") --file contract.json score --title "Use PostgreSQL" \\
      --score 4 --rationale "Production perf benchmarks confirmed"
  $(basename "$0") --file contract.json feedback --decision "ADR-012" \\
      --verdict pass --reviewer "quality-analyst" --notes "Tests cover all branches"

EOF
    exit 0
}

# ── Logging helpers ─────────────────────────────────────────────────────────
# log_pass/log_fail/log_info/log_verbose/log_dry come from scripts/lib.

log_section() {
    echo ""
    echo -e "${BOLD}$1${NC}"
    echo "  $(printf '%*s' "$((${#1} + 2))" '' | tr ' ' '─')"
}

# ── Helpers ─────────────────────────────────────────────────────────────────

# Generate a URL-safe slug from a title string
slugify() {
    local input="$1"
    if command -v python3 &>/dev/null; then
        python3 -c "
import re, sys
s = sys.argv[1]
s = s.lower().strip()
s = re.sub(r'[^a-z0-9]+', '-', s)
s = s.strip('-')
print(s[:80])
" "$input"
    else
        # Fallback: pure bash slug
        local s
        s="$(echo "$input" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')"
        echo "${s:0:80}"
    fi
}

# Generate ISO 8601 timestamp
timestamp_iso() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# ── Validation ──────────────────────────────────────────────────────────────

validate_file() {
    local file="$1"

    if [[ ! -f "$file" ]]; then
        log_fail "File not found: ${file}"
        return 1
    fi

    if ! jq -e '.' "$file" >/dev/null 2>&1; then
        log_fail "Invalid JSON in file: ${file}"
        jq '.' "$file" 2>&1 | head -5 || true
        return 1
    fi

    # Verify required structure exists
    local has_adr
    has_adr="$(jq 'has("decisions") and (.decisions | has("adr_log"))' "$file" 2>/dev/null || echo "false")"
    if [[ "$has_adr" != "true" ]]; then
        log_fail "Contract file missing decisions.adr_log[] — is this a valid contract?"
        return 1
    fi

    local has_scores
    has_scores="$(jq 'has("decisions") and (.decisions | has("confidence_scores"))' "$file" 2>/dev/null || echo "false")"
    if [[ "$has_scores" != "true" ]]; then
        log_fail "Contract file missing decisions.confidence_scores[] — is this a valid contract?"
        return 1
    fi

    return 0
}

# ── Subcommand: list ────────────────────────────────────────────────────────

cmd_list() {
    local file="$1"

    log_section "Decision Journal — List"

    local adr_count
    adr_count="$(jq '.decisions.adr_log | length' "$file" 2>/dev/null || echo 0)"

    local score_count
    score_count="$(jq '.decisions.confidence_scores | length' "$file" 2>/dev/null || echo 0)"

    echo "  ADR entries:     ${adr_count}"
    echo "  Confidence logs: ${score_count}"
    echo ""

    if [[ "$adr_count" -eq 0 ]]; then
        log_info "No ADR entries found in decisions.adr_log[]"
    else
        # Print ADR table header
        printf "  %-3s %-40s %-10s %-25s\n" "#" "Title" "Confidence" "Timestamp"
        printf "  %-3s %-40s %-10s %-25s\n" "---" "----------------------------------------" "----------" "-------------------------"

        local i=0
        while [[ "$i" -lt "$adr_count" ]]; do
            local title
            title="$(jq -r ".decisions.adr_log[$i].decision // .decisions.adr_log[$i].title // \"(untitled)\"" "$file" 2>/dev/null)"
            local conf
            conf="$(jq -r ".decisions.adr_log[$i].confidence // \"-\"" "$file" 2>/dev/null)"
            local ts
            ts="$(jq -r ".decisions.adr_log[$i].timestamp // \"-\"" "$file" 2>/dev/null)"

            # Truncate long titles for table display
            if [[ "${#title}" -gt 37 ]]; then
                title="${title:0:34}..."
            fi

            local num=$((i + 1))
            printf "  %-3d %-40s %-10s %-25s\n" "$num" "$title" "$conf" "$ts"
            i=$((i + 1))
        done
    fi

    echo ""

    if [[ "$score_count" -eq 0 ]]; then
        log_info "No confidence scores found in decisions.confidence_scores[]"
    else
        printf "  %-3s %-40s %-10s %-25s\n" "#" "Title" "Score" "Timestamp"
        printf "  %-3s %-40s %-10s %-25s\n" "---" "----------------------------------------" "----------" "-------------------------"

        local i=0
        while [[ "$i" -lt "$score_count" ]]; do
            local s_title
            s_title="$(jq -r ".decisions.confidence_scores[$i].title // \"(untitled)\"" "$file" 2>/dev/null)"
            local s_score
            s_score="$(jq -r ".decisions.confidence_scores[$i].score // \"-\"" "$file" 2>/dev/null)"
            local s_ts
            s_ts="$(jq -r ".decisions.confidence_scores[$i].timestamp // \"-\"" "$file" 2>/dev/null)"

            if [[ "${#s_title}" -gt 37 ]]; then
                s_title="${s_title:0:34}..."
            fi

            local num=$((i + 1))
            printf "  %-3d %-40s %-10s %-25s\n" "$num" "$s_title" "$s_score" "$s_ts"
            i=$((i + 1))
        done
    fi

    echo ""
    return 0
}

# ── Subcommand: persist ─────────────────────────────────────────────────────

cmd_persist() {
    local file="$1"

    log_section "Decision Journal — Persist"

    # --- Persist ADR entries ---
    local adr_count
    adr_count="$(jq '.decisions.adr_log | length' "$file" 2>/dev/null || echo 0)"
    local persisted_count=0
    local failed_count=0

    if [[ "$adr_count" -eq 0 ]]; then
        log_info "No ADR entries to persist."
    else
        log_info "Persisting ${adr_count} ADR entr${adr_count:+,es}..."

        local i=0
        while [[ "$i" -lt "$adr_count" ]]; do
            local entry_json
            entry_json="$(jq -c ".decisions.adr_log[$i]" "$file" 2>/dev/null || true)"

            if [[ -z "$entry_json" || "$entry_json" == "null" ]]; then
                i=$((i + 1))
                continue
            fi

            # Extract title for slug
            local entry_title
            entry_title="$(echo "$entry_json" | jq -r '.decision // .title // "untitled"' 2>/dev/null)"
            local slug
            slug="$(slugify "$entry_title")"

            log_verbose "  Entry #$((i + 1)): ${slug}"

            if [[ "$DRY_RUN" == true ]]; then
                log_dry "Would persist: decision/${slug}"
                log_verbose "  Value: ${entry_json}"
                persisted_count=$((persisted_count + 1))
            else
                # Persist via lean-ctx if available
                if command -v lean-ctx &>/dev/null; then
                    if lean-ctx ctx_knowledge remember key "decision/${slug}" value "$entry_json" category decisions 2>/dev/null; then
                        log_verbose "  Persisted: decision/${slug}"
                        persisted_count=$((persisted_count + 1))
                    else
                        log_verbose "  lean-ctx returned non-zero for decision/${slug}"
                        failed_count=$((failed_count + 1))
                    fi
                else
                    log_info "lean-ctx not available — would persist to: decision/${slug}"
                    persisted_count=$((persisted_count + 1))
                fi
            fi

            i=$((i + 1))
        done
    fi

    # --- Persist confidence scores ---
    local score_count
    score_count="$(jq '.decisions.confidence_scores | length' "$file" 2>/dev/null || echo 0)"
    local score_persisted=0
    local score_failed=0

    if [[ "$score_count" -gt 0 ]]; then
        log_info "Persisting ${score_count} confidence score${score_count:+,s}..."

        local i=0
        while [[ "$i" -lt "$score_count" ]]; do
            local score_entry
            score_entry="$(jq -c ".decisions.confidence_scores[$i]" "$file" 2>/dev/null || true)"

            if [[ -z "$score_entry" || "$score_entry" == "null" ]]; then
                i=$((i + 1))
                continue
            fi

            local score_title
            score_title="$(echo "$score_entry" | jq -r '.title // "untitled"' 2>/dev/null)"
            local slug
            slug="$(slugify "score-${score_title}")"

            log_verbose "  Score #$((i + 1)): ${score_title}"

            if [[ "$DRY_RUN" == true ]]; then
                log_dry "Would persist: decision/score/${slug}"
                score_persisted=$((score_persisted + 1))
            else
                if command -v lean-ctx &>/dev/null; then
                    if lean-ctx ctx_knowledge remember key "decision/score/${slug}" value "$score_entry" category decisions 2>/dev/null; then
                        log_verbose "  Persisted: decision/score/${slug}"
                        score_persisted=$((score_persisted + 1))
                    else
                        score_failed=$((score_failed + 1))
                    fi
                else
                    log_info "lean-ctx not available — would persist to: decision/score/${slug}"
                    score_persisted=$((score_persisted + 1))
                fi
            fi

            i=$((i + 1))
        done
    fi

    # --- Summary ---
    echo ""
    echo -e "  ${BOLD}Summary:${NC}"
    echo "    ADR entries persisted:     ${persisted_count} / ${adr_count}"
    echo "    Confidence scores recorded: ${score_persisted} / ${score_count}"
    if [[ "$failed_count" -gt 0 || "$score_failed" -gt 0 ]]; then
        echo "    Failures:                  $((failed_count + score_failed))"
    fi

    if [[ "$DRY_RUN" == true ]]; then
        echo ""
        log_info "DRY RUN — nothing was persisted."
        return 0
    fi

    if [[ "$failed_count" -gt 0 || "$score_failed" -gt 0 ]]; then
        log_info "Persist completed with ${failed_count} ADR and ${score_failed} score failures."
        return 1
    fi

    if [[ "$persisted_count" -gt 0 || "$score_persisted" -gt 0 ]]; then
        log_pass "Persist complete: ${persisted_count} decisions + ${score_persisted} scores."
    else
        log_info "Nothing to persist."
    fi

    return 0
}

# ── Subcommand: add ─────────────────────────────────────────────────────────

cmd_add() {
    local file="$1"

    log_section "Decision Journal — Add ADR Entry"

    if [[ -z "$TITLE" ]]; then
        log_fail "--title is required for 'add' command."
        return 2
    fi

    if [[ -z "$DECISION_TEXT" ]]; then
        log_fail "--decision is required for 'add' command."
        return 2
    fi

    # Validate confidence range
    if ! [[ "$CONFIDENCE" =~ ^[1-5]$ ]]; then
        log_fail "Confidence must be 1-5 (got: ${CONFIDENCE})"
        return 2
    fi

    local ts
    ts="$(timestamp_iso)"

    # Build the ADR entry JSON
    local entry
    entry="$(jq -n \
        --arg ts "$ts" \
        --arg context "${CONTEXT}" \
        --arg decision "${DECISION_TEXT}" \
        --arg title "${TITLE}" \
        --arg alternatives "${ALTERNATIVES}" \
        --argjson confidence "$CONFIDENCE" \
        '{
            timestamp: $ts,
            context: $context,
            decision: $decision,
            title: $title,
            alternatives: $alternatives,
            confidence: $confidence,
            confidence_rationale: ""
        }' 2>/dev/null)"

    if [[ -z "$entry" || "$entry" == "null" ]]; then
        log_fail "Failed to build ADR entry JSON."
        return 2
    fi

    log_verbose "ADR entry:"
    log_verbose "  $(echo "$entry" | jq -c '.' 2>/dev/null || echo "$entry")"

    # Preview existing entries
    local current_count
    current_count="$(jq '.decisions.adr_log | length' "$file" 2>/dev/null || echo 0)"

    if [[ "$DRY_RUN" == true ]]; then
        echo ""
        log_dry "Would append ADR entry #$((current_count + 1)):"
        echo "$entry" | jq '.' 2>/dev/null || echo "$entry"
        echo ""
        log_dry "File ${file} would be modified."
        return 0
    fi

    # Append to adr_log array
    local tmp_file
    tmp_file="$(mktemp)"
    jq --argjson entry "$entry" '.decisions.adr_log += [$entry]' "$file" > "$tmp_file" 2>/dev/null || {
        log_fail "Failed to append ADR entry to contract."
        rm -f "$tmp_file"
        return 2
    }

    mv "$tmp_file" "$file"
    log_pass "ADR entry added: ${TITLE}"
    log_verbose "Now: $((current_count + 1)) entries in adr_log"

    return 0
}

# ── Subcommand: score ───────────────────────────────────────────────────────

cmd_score() {
    local file="$1"

    log_section "Decision Journal — Add Confidence Score"

    if [[ -z "$TITLE" ]]; then
        log_fail "--title is required for 'score' command."
        return 2
    fi

    if ! [[ "$SCORE" =~ ^[1-5]$ ]]; then
        log_fail "Score must be 1-5 (got: ${SCORE})"
        return 2
    fi

    local ts
    ts="$(timestamp_iso)"

    # Build score entry
    local score_entry
    score_entry="$(jq -n \
        --arg ts "$ts" \
        --arg title "${TITLE}" \
        --argjson score "$SCORE" \
        --arg rationale "${RATIONALE}" \
        '{
            timestamp: $ts,
            title: $title,
            score: $score,
            rationale: $rationale
        }' 2>/dev/null)"

    if [[ -z "$score_entry" || "$score_entry" == "null" ]]; then
        log_fail "Failed to build score entry JSON."
        return 2
    fi

    log_verbose "Score entry:"
    log_verbose "  $(echo "$score_entry" | jq -c '.' 2>/dev/null || echo "$score_entry")"

    # Preview
    if [[ "$DRY_RUN" == true ]]; then
        echo ""
        log_dry "Would append confidence score:"
        echo "$score_entry" | jq '.' 2>/dev/null || echo "$score_entry"
        echo ""
        log_dry "File ${file} would be modified."
        return 0
    fi

    # Append to confidence_scores array
    local tmp_file
    tmp_file="$(mktemp)"
    jq --argjson entry "$score_entry" '.decisions.confidence_scores += [$entry]' "$file" > "$tmp_file" 2>/dev/null || {
        log_fail "Failed to append score entry to contract."
        rm -f "$tmp_file"
        return 2
    }

    mv "$tmp_file" "$file"
    log_pass "Confidence score added: ${TITLE} = ${SCORE}/5"

    return 0
}

# ── Subcommand: feedback ────────────────────────────────────────────────────

cmd_feedback() {
    local file="$1"

    log_section "Decision Journal — Feedback Entry"

    if [[ -z "$FEEDBACK_DECISION" ]]; then
        log_fail "--decision is required for 'feedback' command."
        return 2
    fi

    if [[ -z "$FEEDBACK_VERDICT" ]]; then
        log_fail "--verdict is required for 'feedback' command."
        return 2
    fi

    if ! [[ "$FEEDBACK_VERDICT" =~ ^(pass|fail|retry)$ ]]; then
        log_fail "Verdict must be pass, fail, or retry (got: ${FEEDBACK_VERDICT})"
        return 2
    fi

    local ts
    ts="$(timestamp_iso)"

    # Build the feedback entry JSON
    local entry
    entry="$(jq -n \
        --arg ts "$ts" \
        --arg decision "${FEEDBACK_DECISION}" \
        --arg verdict "${FEEDBACK_VERDICT}" \
        --arg reviewer "${REVIEWER}" \
        --arg notes "${NOTES}" \
        '{
            timestamp: $ts,
            decision: $decision,
            verdict: $verdict,
            reviewer: $reviewer,
            notes: $notes
        }' 2>/dev/null)"

    if [[ -z "$entry" || "$entry" == "null" ]]; then
        log_fail "Failed to build feedback entry JSON."
        return 2
    fi

    log_verbose "Feedback entry:"
    log_verbose "  $(echo "$entry" | jq -c '.' 2>/dev/null || echo "$entry")"

    # Resolve history file (rules.json → .feedback.feedback_loop.store_in)
    # via scripts/lib store_in_path(); store_in is engine-relative, resolved
    # against PROJECT_DIR here.
    local history
    history="$(store_in_path "feedback.feedback_loop.store_in" "session/feedback-history.json" "$PROJECT_DIR/rules/rules.json")"
    if [[ -n "$history" && ! "$history" = /* ]]; then
        history="$PROJECT_DIR/$history"
    fi

    local current_count=0
    if [[ -f "$history" ]]; then
        current_count="$(jq '.history | length' "$history" 2>/dev/null || echo 0)"
    fi

    if [[ "$DRY_RUN" == true ]]; then
        echo ""
        log_dry "Would append feedback entry #$((current_count + 1)) to ${history}:"
        echo "$entry" | jq '.' 2>/dev/null || echo "$entry"
        echo ""
        return 0
    fi

    # Append (file may not exist yet — initialize as {"history": []})
    mkdir -p "$(dirname "$history")"
    if [[ ! -f "$history" ]]; then
        jq -n '{history: []}' > "$history" 2>/dev/null || {
            log_fail "Failed to initialize feedback history file: ${history}"
            return 2
        }
    fi

    local tmp_file
    tmp_file="$(mktemp)"
    jq --argjson entry "$entry" '.history += [$entry]' "$history" > "$tmp_file" 2>/dev/null || {
        log_fail "Failed to append feedback entry to ${history}"
        rm -f "$tmp_file"
        return 2
    }

    mv "$tmp_file" "$history"
    log_pass "Feedback entry added: ${FEEDBACK_DECISION} = ${FEEDBACK_VERDICT}"
    log_verbose "Now: $((current_count + 1)) entries in ${history}"

    return 0
}

# ── Main ────────────────────────────────────────────────────────────────────
main() {
    # Collect all args; we need to parse global flags first, then subcommand,
    # then subcommand-specific args.

    local parsed_subcommand=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                HELP=true
                shift
                ;;
            --file)
                if [[ -z "${2:-}" ]]; then
                    log_fail "--file requires a path argument."
                    exit 2
                fi
                CONTRACT_FILE="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            # Subcommands
            list|persist|add|score|feedback)
                COMMAND="$1"
                parsed_subcommand=true
                shift
                # Parse subcommand-specific args
                case "$COMMAND" in
                    add)
                        while [[ $# -gt 0 ]]; do
                            case "$1" in
                                --title)
                                    TITLE="$2"
                                    shift 2
                                    ;;
                                --decision)
                                    DECISION_TEXT="$2"
                                    shift 2
                                    ;;
                                --context)
                                    CONTEXT="$2"
                                    shift 2
                                    ;;
                                --alternatives)
                                    ALTERNATIVES="$2"
                                    shift 2
                                    ;;
                                --confidence)
                                    CONFIDENCE="$2"
                                    shift 2
                                    ;;
                                *)
                                    echo -e "${RED}Unknown add option:${NC} $1" >&2
                                    echo "Try '$(basename "$0") --help' for more info." >&2
                                    exit 2
                                    ;;
                            esac
                        done
                        ;;
                    score)
                        while [[ $# -gt 0 ]]; do
                            case "$1" in
                                --title)
                                    TITLE="$2"
                                    shift 2
                                    ;;
                                --score)
                                    SCORE="$2"
                                    shift 2
                                    ;;
                                --rationale)
                                    RATIONALE="$2"
                                    shift 2
                                    ;;
                                *)
                                    echo -e "${RED}Unknown score option:${NC} $1" >&2
                                    echo "Try '$(basename "$0") --help' for more info." >&2
                                    exit 2
                                    ;;
                            esac
                        done
                        ;;
                    feedback)
                        while [[ $# -gt 0 ]]; do
                            case "$1" in
                                --decision)
                                    FEEDBACK_DECISION="$2"
                                    shift 2
                                    ;;
                                --verdict)
                                    FEEDBACK_VERDICT="$2"
                                    shift 2
                                    ;;
                                --reviewer)
                                    REVIEWER="$2"
                                    shift 2
                                    ;;
                                --notes)
                                    NOTES="$2"
                                    shift 2
                                    ;;
                                *)
                                    echo -e "${RED}Unknown feedback option:${NC} $1" >&2
                                    echo "Try '$(basename "$0") --help' for more info." >&2
                                    exit 2
                                    ;;
                            esac
                        done
                        ;;
                esac
                ;;
            *)
                echo -e "${RED}Unknown option:${NC} $1" >&2
                echo "Try '$(basename "$0") --help' for more info." >&2
                exit 2
                ;;
        esac
    done

    # Show help first
    if [[ "$HELP" == true ]]; then
        usage
    fi

    # Must have a subcommand
    if [[ -z "$COMMAND" ]]; then
        echo -e "${RED}Error:${NC} No command specified." >&2
        echo "Try '$(basename "$0") --help' for more info." >&2
        exit 2
    fi

    # Pre-flight checks
    if ! command -v jq &>/dev/null; then
        log_fail "jq is required but not installed."
        exit 2
    fi

    # Resolve contract file path
    if [[ -z "$CONTRACT_FILE" ]]; then
        log_fail "--file PATH is required."
        echo "Try '$(basename "$0") --help' for more info." >&2
        exit 2
    fi

    # Resolve relative paths
    if [[ ! "$CONTRACT_FILE" = /* ]]; then
        CONTRACT_FILE="$PROJECT_DIR/$CONTRACT_FILE"
    fi

    # Validate contract file (all commands need it)
    if ! validate_file "$CONTRACT_FILE"; then
        exit 2
    fi

    # Log header
    log_section "$(basename "$0") — Decision Journal"
    echo "  File:    ${CYAN}${CONTRACT_FILE}${NC}"
    echo "  Command: ${CYAN}${COMMAND}${NC}"
    echo "  Dry-run: ${CYAN}${DRY_RUN}${NC}"
    echo "  Verbose: ${CYAN}${VERBOSE}${NC}"

    # Dispatch
    local exit_code=0
    case "$COMMAND" in
        list)
            cmd_list "$CONTRACT_FILE"
            exit_code=$?
            ;;
        persist)
            cmd_persist "$CONTRACT_FILE"
            exit_code=$?
            ;;
        add)
            cmd_add "$CONTRACT_FILE"
            exit_code=$?
            ;;
        score)
            cmd_score "$CONTRACT_FILE"
            exit_code=$?
            ;;
        feedback)
            cmd_feedback "$CONTRACT_FILE"
            exit_code=$?
            ;;
        *)
            log_fail "Unknown command: ${COMMAND}"
            exit 2
            ;;
    esac

    exit "$exit_code"
}

main "$@"