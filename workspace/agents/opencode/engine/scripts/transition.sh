#!/usr/bin/env bash
# transition.sh — the ONLY sanctioned way to mutate contract.state.
# Serializes writers with the shared directory lock, validates through the
# controller, checks the completion policy on the COMPLETE edge, then writes
# atomically.
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

source "$SCRIPT_DIR/lib/common.sh"
acquire_file_lock "$CONTRACT" || exit 1
trap release_file_lock EXIT
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

# Governance graph event: emit on every successful state mutation.
# The emitter is best-effort (no-op when GOVERNANCE_GRAPH_ENABLED=false) and
# never fails its caller, so graph capture cannot break a transition.
task_id="$(jq -r ".task_id // .session.task_id // empty" "$CONTRACT" 2>/dev/null || true)"
score="$(jq -r ".score.combined // empty" "$CONTRACT" 2>/dev/null || true)"
phase="${TO%_SCORED}"
extra="$(jq -nc --arg from "$FROM" --arg to "$TO" "{from:\$from,to:\$to}" 2>/dev/null || printf "%s" "{}")"
bash "$SCRIPT_DIR/governance-event.sh" \
    --event "$TO" \
    --task "${task_id:-unknown}" \
    --phase "$phase" \
    --score "$score" \
    --agent "$AGENT" \
    --evidence "$EVIDENCE" \
    --extra "$extra" \
    >/dev/null 2>&1 || true

# Drain the spool to FalkorDB best-effort after the state is committed.
# A disabled graph or unreachable DB must never fail the transition.
if [[ "${GOVERNANCE_GRAPH_ENABLED:-true}" == "true" ]]; then
    bash "$SCRIPT_DIR/governance-graph-ingest.sh" >/dev/null 2>&1 || true
fi
echo "state: $FROM -> $TO"
