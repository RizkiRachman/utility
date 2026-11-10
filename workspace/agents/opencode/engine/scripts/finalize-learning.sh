#!/usr/bin/env bash
# finalize-learning.sh - UP5: single-writer learning finalization
# Persists the envelope under the task-namespaced knowledge key and archives state.
# Called by the learner agent INSTEAD of ad-hoc multi-step persistence.
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
if ! kb_remember "$CONTRACT_JSON" "$KEY" state >/dev/null 2>&1; then
    echo "ERROR: knowledge persist failed for $KEY" >&2
    exit 1
fi
bash "${SCRIPT_DIR}/snapshot-contract.sh" --snapshot-only >/dev/null 2>&1 || true
echo "finalize-learning: envelope persisted to $KEY"


