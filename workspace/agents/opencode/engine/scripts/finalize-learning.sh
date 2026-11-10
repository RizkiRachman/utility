#!/usr/bin/env bash
# finalize-learning.sh - UP5: single-writer learning finalization
# Persists the envelope under the task-namespaced knowledge key and archives state.
# Called by the learner agent INSTEAD of ad-hoc multi-step persistence.
# Lock: acquires the same exclusive flock on <contract>.lock (fd 9) that
# persist-contract.sh holds, from the knowledge write until process exit.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/paths.sh"
source "${SCRIPT_DIR}/lib/knowledge.sh"
CONTRACT_FILE="${1:-}"
if [[ -z "$CONTRACT_FILE" || ! -f "$CONTRACT_FILE" ]]; then
    echo "ERROR: contract file required: $0 <contract.json>" >&2
    exit 2
fi
TASK_ID=$(jq -r '.session.task_id // "default"' "$CONTRACT_FILE")
KEY="orchestration-contract:${TASK_ID}"
CONTRACT_JSON=$(cat "$CONTRACT_FILE")
# R3-18: single-writer lock, same flock contract as persist-contract.sh
# Group form: keeps fd 2 alive (bare `exec 9>f 2>/dev/null` would silence all
# later stderr, hiding the archive-failure error below).
{ exec 9>"${CONTRACT_FILE}.lock"; } 2>/dev/null || true
flock 9 2>/dev/null || true
if ! kb_remember "$CONTRACT_JSON" "$KEY" state >/dev/null 2>&1; then
    echo "ERROR: knowledge persist failed for $KEY" >&2
    exit 1
fi
# R3-08: archive failure is a distinct, non-zero outcome (envelope already persisted)
if ! bash "${SCRIPT_DIR}/snapshot-contract.sh" --snapshot-only >/dev/null 2>&1; then
    echo "ERROR: envelope persisted to $KEY but archive snapshot FAILED (session/archive is stale)" >&2
    exit 3
fi
echo "finalize-learning: envelope persisted to $KEY"


