#!/usr/bin/env bash
# transition.sh — the ONLY sanctioned way to mutate contract.state.
# Validates via the central controller, writes atomically, then emits the
# immutable post-transition audit event.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACT="${CONTRACT_FILE:-session/contract.json}"
TO="" AGENT="" EVIDENCE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --to) TO="$2"; shift 2 ;; --agent) AGENT="$2"; shift 2 ;;
    --evidence) EVIDENCE="$2"; shift 2 ;;
    *) echo "transition.sh: unknown arg $1" >&2; exit 2 ;;
  esac
done
[[ -n "$TO" && -n "$EVIDENCE" ]] || { echo "usage: transition.sh --to STATE --agent NAME --evidence ID" >&2; exit 2; }
[[ -f "$CONTRACT" ]] || { echo "transition.sh: contract not found: $CONTRACT" >&2; exit 1; }
FROM=$(jq -r '.state // "INIT"' "$CONTRACT")
bash "$SCRIPT_DIR/workflow-controller.sh" pre_transition --to "$TO" --agent "$AGENT" --evidence "$EVIDENCE" || exit 1
jq --arg to "$TO" '.state = $to' "$CONTRACT" > "${CONTRACT}.new" || exit 1
mv "${CONTRACT}.new" "$CONTRACT" || exit 1
bash "$SCRIPT_DIR/workflow-controller.sh" post_transition --from "$FROM" --to "$TO"
echo "state: $FROM -> $TO"
