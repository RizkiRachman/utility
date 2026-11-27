#!/usr/bin/env bash
# failure-loop.sh — typed, mechanical failure-loop strategy selection.
# Replaces ad-hoc "retry with the same approach" loops with an explicit
# strategy per failure class. Emits a JSON decision and an exit code.
#   exit 0 = RETRY_WITH_GUIDANCE | 2 = CHANGE_APPROACH
#   exit 3 = ESCALATE              | 4 = BLOCKED
set -uo pipefail
TYPE=""; ATTEMPT=""; MAX=""; HASH=""; LAST=""; TASK=""; PHASE=""
require_value() {
  local option="$1"
  if (( $# < 2 )) || [[ -z "$2" ]]; then
    echo "failure-loop.sh: $option requires a non-empty value" >&2
    exit 5
  fi
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --type) require_value "$@"; TYPE="$2"; shift 2 ;;
    --attempt) require_value "$@"; ATTEMPT="$2"; shift 2 ;;
    --max) require_value "$@"; MAX="$2"; shift 2 ;;
    --hash) require_value "$@"; HASH="$2"; shift 2 ;;
    --last-hash) require_value "$@"; LAST="$2"; shift 2 ;;
    --task) require_value "$@"; TASK="$2"; shift 2 ;;
    --phase) require_value "$@"; PHASE="$2"; shift 2 ;;
    *) echo "failure-loop.sh: unknown arg $1" >&2; exit 5 ;;
  esac
done
ATTEMPT=${ATTEMPT:-1}; MAX=${MAX:-3}
[[ -n "$TYPE" ]] || { echo "usage: failure-loop.sh --type CLASS [--attempt N --max N --hash H --last-hash H]" >&2; exit 5; }
[[ "$ATTEMPT" =~ ^[1-9][0-9]{0,14}$ ]] || { echo "failure-loop.sh: --attempt must be a positive integer with at most 15 digits" >&2; exit 5; }
[[ "$MAX" =~ ^[1-9][0-9]{0,14}$ ]] || { echo "failure-loop.sh: --max must be a positive integer with at most 15 digits" >&2; exit 5; }
command -v jq >/dev/null 2>&1 || { echo "failure-loop.sh: jq is required to emit a decision" >&2; exit 5; }

decide() {
  local strategy="$1" reason="$2" code="$3"
  jq -cn --arg t "$TYPE" --arg s "$strategy" --arg r "$reason" \
    --argjson a "$ATTEMPT" --argjson m "$MAX" --arg p "${PHASE:-}" --arg k "${TASK:-}" \
    '{type:$t,attempt:$a,max:$m,strategy:$s,reason:$r,phase:$p,task:$k}' 2>/dev/null || {
      echo "failure-loop.sh: unable to serialize decision" >&2
      exit 5
    }
  exit "$code"
}

# Deterministic failure classes: a repeat with the same evidence hash can never
# succeed, so change the approach rather than spend another attempt.
case "$TYPE" in
  compile|convention|malformed|model-drift)
    [[ "$ATTEMPT" -ge "$MAX" ]] && decide BLOCKED "deterministic $TYPE failed at attempt limit" 4
    decide CHANGE_APPROACH "$TYPE is deterministic; patch the root cause, do not retry" 2 ;;
  security)
    decide ESCALATE "security-sensitive failure requires security-engineer review" 3 ;;
  test)
    [[ -n "$HASH" && "$HASH" == "$LAST" ]] && decide CHANGE_APPROACH "identical test evidence; change the test or fix, not the retry" 2
    [[ "$ATTEMPT" -ge "$MAX" ]] && decide BLOCKED "test failures exhausted attempt limit" 4
    decide RETRY_WITH_GUIDANCE "collect failure output and retry with targeted guidance" 0 ;;
  review|gate)
    [[ -n "$HASH" && "$HASH" == "$LAST" ]] && decide CHANGE_APPROACH "identical review evidence; change the approach" 2
    [[ "$ATTEMPT" -ge "$MAX" ]] && decide ESCALATE "review/gate still failing after $MAX attempts; escalate for arbitration" 3
    decide RETRY_WITH_GUIDANCE "address review findings and re-score" 0 ;;
  timeout|flaky)
    [[ "$ATTEMPT" -ge "$MAX" ]] && decide ESCALATE "transient failure persisted after $MAX attempts" 3
    decide RETRY_WITH_GUIDANCE "transient $TYPE; bounded retry with backoff" 0 ;;
  *)
    [[ -n "$HASH" && "$HASH" == "$LAST" ]] && decide CHANGE_APPROACH "identical attempt hash; change the approach" 2
    [[ "$ATTEMPT" -ge "$MAX" ]] && decide BLOCKED "attempt limit reached" 4
    decide RETRY_WITH_GUIDANCE "unknown failure class; bounded retry" 0 ;;
esac
