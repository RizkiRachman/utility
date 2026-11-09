#!/usr/bin/env bash
set -euo pipefail

# ─── Config ────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULES_FILE="$(ls "$SCRIPT_DIR/../rules/rules.json" 2>/dev/null || true)"
if [[ -z "$RULES_FILE" && -f /opt/engine/rules/rules.json ]]; then
  RULES_FILE="/opt/engine/rules/rules.json"
fi
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# ─── Help ──────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") --agent NAME (--contract PATH | --state STATE | --contract-dir DIR) [--blast-radius LEVEL] [--dry-run]

Agent state guard — verifies an agent is allowed in the current contract state
and optionally validates blast radius acknowledgment.

Options:
  --agent NAME         Agent name (must match a key in rules.json agent_states)
  --contract PATH      Path to contract.json (mutually exclusive with --state/--contract-dir)
  --state STATE        State string override (mutually exclusive with --contract/--contract-dir)
  --contract-dir DIR   Session directory — auto-detects contract.json at DIR/contract.json
  --blast-radius LEVEL WARN if blast radius not acknowledged at given level (HIGH|CRITICAL)
  --to STATE           Verify transition CURRENT -> STATE is legal per rules.json edges
  --dry-run            Show each step without exiting
  --help               Show this message

Examples:
  $(basename "$0") --agent system-analyst --contract contract.json
  $(basename "$0") --agent developer --state EXECUTE
  $(basename "$0") --agent orchestrator --contract-dir session/my-session
  $(basename "$0") --agent developer --contract-dir session --blast-radius HIGH
EOF
  exit 0
}

# ─── Parse flags ───────────────────────────────────────────────────────────
AGENT=""
CONTRACT=""
CONTRACT_DIR=""
STATE=""
BLAST_RADIUS=""
DRY_RUN=false
TARGET_TO=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --agent)
      AGENT="$2"
      shift 2
      ;;
    --contract)
      CONTRACT="$2"
      shift 2
      ;;
    --contract-dir)
      CONTRACT_DIR="$2"
      shift 2
      ;;
    --state)
      STATE="$2"
      shift 2
      ;;
    --blast-radius)
      BLAST_RADIUS="$2"
      if [[ "$BLAST_RADIUS" != "HIGH" && "$BLAST_RADIUS" != "CRITICAL" ]]; then
        echo -e "${RED}ERROR: --blast-radius must be HIGH or CRITICAL${NC}" >&2
        exit 1
      fi
      shift 2
      ;;
    --to)
      TARGET_TO="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --help)
      usage
      ;;
    *)
      echo -e "${RED}ERROR: Unknown option: $1${NC}" >&2
      usage
      ;;
  esac
done

# Resolve contract-dir to contract path
if [[ -n "$CONTRACT_DIR" ]]; then
  if [[ -f "$CONTRACT_DIR/contract.json" ]]; then
    CONTRACT="$CONTRACT_DIR/contract.json"
  else
    echo -e "${RED}ERROR: contract.json not found in directory: $CONTRACT_DIR${NC}" >&2
    exit 1
  fi
fi

# ─── Validate inputs ───────────────────────────────────────────────────────
if [[ -z "$AGENT" ]]; then
  echo -e "${RED}ERROR: --agent is required${NC}" >&2
  usage
fi

if [[ -n "$CONTRACT" && -n "$STATE" ]]; then
  echo -e "${RED}ERROR: --contract, --contract-dir, and --state are mutually exclusive${NC}" >&2
  exit 1
fi

if [[ -z "$CONTRACT" && -z "$STATE" ]]; then
  echo -e "${RED}ERROR: Either --contract, --contract-dir, or --state is required${NC}" >&2
  usage
fi

# ─── Check jq availability ────────────────────────────────────────────────
if ! command -v jq &>/dev/null; then
  echo -e "${RED}ERROR: jq is required but not installed${NC}" >&2
  exit 1
fi

# ─── Check rules file ──────────────────────────────────────────────────────
if [[ ! -f "$RULES_FILE" ]]; then
  echo -e "${RED}ERROR: Rules file not found: $RULES_FILE${NC}" >&2
  exit 1
fi

if $DRY_RUN; then
  echo -e "${YELLOW}[DRY-RUN] Rules file found: $RULES_FILE${NC}"
fi

# ─── Resolve agent allowed states ──────────────────────────────────────────
# rules.json declares agent_states at the top level (not under state_machine)
ALLOWED=$(jq -r --arg agent "$AGENT" '
  .agent_states[$agent] // empty | @json
' "$RULES_FILE")

if [[ -z "$ALLOWED" ]]; then
  echo -e "${RED}ERROR: Agent '$AGENT' not found in rules.json agent_states${NC}" >&2
  exit 1
fi

if $DRY_RUN; then
  echo -e "${YELLOW}[DRY-RUN] Agent '$AGENT' allowed states: $ALLOWED${NC}"
fi

# ─── Resolve current state ─────────────────────────────────────────────────
CURRENT_STATE=""

if [[ -n "$STATE" ]]; then
  CURRENT_STATE="$STATE"
  if $DRY_RUN; then
    echo -e "${YELLOW}[DRY-RUN] Using --state override: $CURRENT_STATE${NC}"
  fi
elif [[ -n "$CONTRACT" ]]; then
  if [[ ! -f "$CONTRACT" ]]; then
    echo -e "${RED}ERROR: Contract file not found: $CONTRACT${NC}" >&2
    exit 1
  fi
  CURRENT_STATE=$(jq -r '.state // empty' "$CONTRACT")
  if [[ -z "$CURRENT_STATE" ]]; then
    echo -e "${RED}ERROR: No .state field found in contract: $CONTRACT${NC}" >&2
    exit 1
  fi
  if $DRY_RUN; then
    echo -e "${YELLOW}[DRY-RUN] Read state from contract '$CONTRACT': $CURRENT_STATE${NC}"
  fi
fi

# --- Subagent Limits Check (N16) ---
if [[ -n "$CONTRACT" && -f "$CONTRACT" ]]; then
  DEPTH=$(jq -r ".governance.subagent_depth // 0" "$CONTRACT")
  DELEG=$(jq -r ".governance.delegations_used // 0" "$CONTRACT")
  MAXD=$(jq -r ".enforcement.subagent_limits.max_depth // 2" "$RULES_FILE")
  MAXG=$(jq -r ".enforcement.subagent_limits.max_delegations_per_session // 20" "$RULES_FILE")
  if (( DEPTH > MAXD )); then
    echo -e "${RED}BLOCKED: subagent depth $DEPTH exceeds max_depth $MAXD${NC}" >&2
    exit 1
  fi
  if (( DELEG >= MAXG )); then
    echo -e "${RED}BLOCKED: delegations $DELEG reached per-session limit $MAXG${NC}" >&2
    exit 1
  fi
  if $DRY_RUN; then
    echo -e "${YELLOW}[DRY-RUN] Subagent limits: depth $DEPTH/$MAXD, delegations $DELEG/$MAXG${NC}"
  fi
fi
# ─── Evaluate ──────────────────────────────────────────────────────────────
if [[ "$ALLOWED" == '["*"]' ]]; then
  echo -e "${GREEN}PASS: Agent '$AGENT' allowed in state $CURRENT_STATE (wildcard)${NC}"
fi  # N3: no early exit - wildcard agents still obey transition gates

ALLOWED_LIST=$(echo "$ALLOWED" | jq -r '.[]')
IS_ALLOWED=false

while IFS= read -r allowed_state; do
  if [[ "$allowed_state" == "*" || "$allowed_state" == "$CURRENT_STATE" ]]; then
    IS_ALLOWED=true
    break
  fi
done <<< "$ALLOWED_LIST"

if $IS_ALLOWED; then
  echo -e "${GREEN}PASS: Agent '$AGENT' allowed in state $CURRENT_STATE${NC}"
else
  ALLOWED_CSV=$(echo "$ALLOWED_LIST" | paste -sd ", " -)
  echo -e "${RED}BLOCKED: Agent '$AGENT' not allowed in state $CURRENT_STATE. Allowed: $ALLOWED_CSV${NC}" >&2
  exit 1
fi


# --- Transition Legality Check (N3) ---
if [[ -n "$TARGET_TO" ]]; then
  EDGE=$(jq -r --arg from "$CURRENT_STATE" --arg to "$TARGET_TO" '
    .state_machine.transitions[]
    | select((.from == $from or .from == "*") and .to == $to)
    | @json' "$RULES_FILE" 2>/dev/null | head -n 1)
  if [[ -z "$EDGE" ]]; then
    echo -e "${RED}BLOCKED: transition $CURRENT_STATE -> $TARGET_TO is not declared in rules.json${NC}" >&2
    exit 1
  fi
  if $DRY_RUN; then
    echo -e "${YELLOW}[DRY-RUN] Edge: $EDGE${NC}"
  fi
  EDGE_SCORE_LT=$(echo "$EDGE" | jq -r ".score_lt // empty")
  EDGE_REQ=$(echo "$EDGE" | jq -r ".requires // empty")
  if [[ -n "$EDGE_SCORE_LT" || -n "$EDGE_REQ" ]] && [[ -z "$CONTRACT" || ! -f "$CONTRACT" ]]; then
    echo -e "${RED}BLOCKED: edge $CURRENT_STATE -> $TARGET_TO carries gates but no contract file was provided${NC}" >&2
    exit 1
  fi
  if [[ -n "$EDGE_SCORE_LT" && -f "$CONTRACT" ]]; then
    ESC_SCORE=$(jq -r ".score.combined // 0" "$CONTRACT")
    if (( ${ESC_SCORE%%.*} >= ${EDGE_SCORE_LT%%.*} )); then
      echo -e "${RED}BLOCKED: escalation edge requires score < $EDGE_SCORE_LT (got $ESC_SCORE); use the RETRY path${NC}" >&2
      exit 1
    fi
  fi
  if [[ "$EDGE_REQ" == "user_override" && -f "$CONTRACT" ]]; then
    if [[ "$(jq -r ".governance.user_override // false" "$CONTRACT")" != "true" ]]; then
      echo -e "${RED}BLOCKED: transition requires governance.user_override=true${NC}" >&2
      exit 1
    fi
  fi
  if [[ "$EDGE_REQ" == "retry_allowed" && -f "$CONTRACT" ]]; then
    R_ATT=$(jq -r ".retry.attempt // 0" "$CONTRACT")
    R_MAX=$(jq -r ".retry.max_attempts // 3" "$CONTRACT")
    if (( R_ATT >= R_MAX )); then
      echo -e "${RED}BLOCKED: retry exhausted ($R_ATT/$R_MAX); BLOCKED is the only legal path${NC}" >&2
      exit 1
    fi
  fi
  echo -e "${GREEN}PASS: transition $CURRENT_STATE -> $TARGET_TO is legal${NC}"
fi
# ─── Blast Radius Check ─────────────────────────────────────────────────────
# --- Blast Radius Check (N3: HIGH/CRITICAL unacknowledged = BLOCKED) ---
if [[ -n "$BLAST_RADIUS" ]]; then
  if [[ -z "$CONTRACT" || ! -f "$CONTRACT" ]]; then
    echo -e "${RED}BLOCKED: blast radius $BLAST_RADIUS declared but no contract file to verify acknowledgment${NC}" >&2
    exit 1
  fi
  acknowledged=$(jq -r ".governance.blast_radius_acknowledged // false" "$CONTRACT" 2>/dev/null || echo "false")
  if [[ "$acknowledged" != "true" ]]; then
    echo -e "${RED}BLOCKED: blast radius $BLAST_RADIUS not acknowledged in contract.governance.blast_radius_acknowledged${NC}" >&2
    echo -e "${RED}  Run ctx_impact, record the risk, then set governance.blast_radius_acknowledged=true${NC}" >&2
    exit 1
  fi
  echo -e "${GREEN}PASS: blast radius $BLAST_RADIUS acknowledged${NC}"
fi