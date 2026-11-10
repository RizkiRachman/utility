#!/usr/bin/env bash
# recall-test.sh - prove the learning loop recalls, not just writes (R2-14).
# Writes a unique marker lesson via the knowledge CLI, recalls it back, and
# fails when the marker does not come back. Runs unattended via
# scheduled-runner.sh (task: recall-test) so a silently broken knowledge
# store is caught by the scheduler instead of by a surprised agent.
# Exit codes: 0 = marker recalled, 1 = recall miss, 2 = write/tool failure.
set -uo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/lib/knowledge.sh"

MARKER="RECALLTEST-$(date +%s)"
KEY="recall-test"
VALUE="recall-test verification lesson ${MARKER}"
QUERY="recall-test verification lesson"

echo "[recall-test] writing marker ${MARKER} under key ${KEY}"
if ! kb_remember "${VALUE}" "${KEY}" verification >/dev/null 2>&1; then
    echo "[recall-test] FAIL: knowledge write failed" >&2
    exit 2
fi

echo "[recall-test] recalling via query: ${QUERY}"
RESULT="$(kb_recall "${QUERY}" 2>/dev/null || true)"

if echo "${RESULT}" | grep -q "${MARKER}"; then
    echo "[recall-test] PASS: ${MARKER} recalled from knowledge store"
    exit 0
fi

echo "[recall-test] FAIL: ${MARKER} not present in recall output" >&2
echo "${RESULT}" | head -5 >&2 || true
exit 1
