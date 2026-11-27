#!/usr/bin/env bash
# transition.sh — the ONLY sanctioned way to mutate contract.state.
# Serializes writers with flock, validates through the controller, checks the
# completion policy on the COMPLETE edge, then writes atomically.
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
[[ -n "$TO" && -n "$AGENT" && -n "$EVIDENCE" ]] || { echo "usage: transition.sh --to STATE --agent NAME --evidence ID" >&2; exit 2; }
[[ -f "$CONTRACT" ]] || { echo "transition.sh: contract not found: $CONTRACT" >&2; exit 1; }

if command -v flock >/dev/null 2>&1; then
  exec 9>"${CONTRACT}.lock" || exit 1
  flock -x 9 || exit 1
else
  LOCKDIR="${CONTRACT}.lockdir"
  LOCKED=false
  for _ in $(seq 1 100); do
    if mkdir "$LOCKDIR" 2>/dev/null; then LOCKED=true; break; fi
    sleep 0.02
  done
  [[ "$LOCKED" == true ]] || { echo "transition.sh: lock timeout" >&2; exit 1; }
  trap 'rmdir "$LOCKDIR" 2>/dev/null || true' EXIT
fi
FROM=$(jq -r '.state // "INIT"' "$CONTRACT") || exit 1

if [[ "$TO" == "COMPLETE" ]]; then
  bash "$SCRIPT_DIR/workflow-controller.sh" pre_completion --agent "$AGENT" || exit 1
fi
bash "$SCRIPT_DIR/workflow-controller.sh" pre_transition --to "$TO" --agent "$AGENT" --evidence "$EVIDENCE" || exit 1
stamp=""
if [[ "$TO" == "BLOCKED" ]]; then stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; fi
jq --arg to "$TO" --arg from "$FROM" --arg stamp "$stamp" --arg ts "$stamp" '
  .state = $to
  | if $to == "BLOCKED" then
      .retry.blocked_at = $stamp
      | .retry.escalation_trace += [{
          phase: (.retry.current_phase // ""), blocked_at: $stamp,
          reason: "blocked via transition.sh", issues: (.retry.issues // []),
          attempt: (.retry.attempt // 0)
        }]
    elif $from == "BLOCKED" then .retry.blocked_at = null
    else . end
' "$CONTRACT" > "${CONTRACT}.new" || exit 1
mv "${CONTRACT}.new" "$CONTRACT" || exit 1
bash "$SCRIPT_DIR/workflow-controller.sh" post_transition --from "$FROM" --to "$TO" || exit 1
echo "state: $FROM -> $TO"
