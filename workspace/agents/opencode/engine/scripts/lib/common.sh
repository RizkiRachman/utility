#!/usr/bin/env bash
#
# lib/common.sh — Canonical shared helpers for engine/scripts (MOD phase 1)
#
# Sourced by scripts/*.sh as:
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
#
# Canonical logging semantics (dominant toolkit convention):
#   log_pass/log_ok  "  [PASS]/[OK] <msg>"  GREEN,  stdout, always prints
#   log_fail         "  [FAIL] <msg>"       RED,    stdout, always prints
#   log_info         "  [INFO] <msg>"       YELLOW, stdout, always prints
#   log_warn         "  [WARN] <msg>"       YELLOW, stdout, always prints
#   log_verbose      "  [VERB] <msg>"       CYAN,   stdout, only when VERBOSE=true
#   log_dry          "  [DRY-RUN] <msg>"    CYAN,   stdout, always prints
#
# Deliberately NOT centralized (semantics differ; scripts keep local versions):
#   counter/strict-mode logging  (check-cross-references.sh, validate-toolkit.sh,
#                                check-conventions.sh, check-doc-style.sh)
#   JSON output mode             (health-check.sh)
#   stderr-stream logging        (auto-score.sh, self-healing-retry.sh, session-lock.sh)
#   glyph format (✗/ℹ)           (contract-enforcer.sh, scheduled-runner.sh)
#   EXIT_CODE-setting variants   (snapshot-contract.sh, self-repair.sh,
#                                archive-sessions.sh, session-lock.sh)
#   fancy log_section variants   (decision-journal.sh, prototype-mode.sh, ...)

# Re-sourcing is a no-op (guard must be an if — a bare `&& return` would
# return nonzero under `set -e` on first load).
if [[ -n "${_LCOMMON_Sourced:-}" ]]; then
    return 0
fi
_LCOMMON_Sourced=1

_LCOMMON_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LCOMMON_ENGINE_ROOT="$(cd "$_LCOMMON_LIB_DIR/../.." && pwd)"
_LCOMMON_RULES_FILE="$_LCOMMON_ENGINE_ROOT/rules/rules.json"

# ── Colors ──────────────────────────────────────────────────────────────────
# Only set when not already defined by the sourcing script; empty when stdout
# is not a terminal. Scripts that define colors after sourcing always win.
if [[ -z "${NC:-}" ]]; then
    if [[ -t 1 ]]; then
        RED='\033[0;31m'
        GREEN='\033[0;32m'
        YELLOW='\033[1;33m'
        CYAN='\033[0;36m'
        NC='\033[0m'
    else
        RED=''
        GREEN=''
        YELLOW=''
        CYAN=''
        NC=''
    fi
fi

# ── Logging helpers ─────────────────────────────────────────────────────────
log_pass() { echo -e "  ${GREEN}[PASS]${NC} $*"; }
log_ok() { log_pass "$@"; }
log_fail() { echo -e "  ${RED}[FAIL]${NC} $*"; }
log_info() { echo -e "  ${YELLOW}[INFO]${NC} $*"; }
log_warn() { echo -e "  ${YELLOW}[WARN]${NC} $*"; }
log_verbose() { if [[ "${VERBOSE:-false}" == true ]]; then echo -e "  ${CYAN}[VERB]${NC} $*"; fi; }
log_dry() { echo -e "  ${CYAN}[DRY-RUN]${NC} $*"; }

# ── Violations counter ──────────────────────────────────────────────────────
# Shared counter for checker scripts that do not need the full
# counter/strict-mode logging family.
init_violations() { VIOLATIONS=0; }
bump_violations() { VIOLATIONS=$((VIOLATIONS + 1)); }

# ── rules.json store_in resolution ─────────────────────────────────────────
# store_in_path DOTTED_PATH [FALLBACK] [RULES_FILE]
#
# Prints the raw `store_in` string found at DOTTED_PATH (dot-separated keys,
# e.g. "feedback.feedback_loop.store_in") inside RULES_FILE, or FALLBACK when
# the path is missing or null. The value is returned as-is — callers resolve
# relative paths against their own project/engine root.
#
# Default RULES_FILE is the engine root resolved relative to this lib file
# (works both from the repo checkout and from /opt/engine in the container).
# Dependency-light: plain jq, guarded by command -v.
store_in_path() {
    local dotted="$1"
    local fallback="${2:-}"
    local rules="${3:-$_LCOMMON_RULES_FILE}"
    local p=""
    if [[ -n "$dotted" && -f "$rules" ]] && command -v jq &>/dev/null; then
        p="$(jq -r --arg d "$dotted" 'getpath($d | split(".")) // empty' "$rules" 2>/dev/null || true)"
    fi
    if [[ -z "$p" || "$p" == "null" ]]; then
        p="$fallback"
    fi
    printf '%s\n' "$p"
}
