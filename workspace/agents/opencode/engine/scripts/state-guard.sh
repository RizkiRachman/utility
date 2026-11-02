#!/usr/bin/env bash
set -euo pipefail

# ─── Config ────────────────────────────────────────────────────────────────
RULES_FILE="rules/rules.json"
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
ALLOWED=$(jq -r --arg agent "$AGENT" '
  .state_machine.agent_states[$agent] // empty | @json
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

# ─── Evaluate ──────────────────────────────────────────────────────────────
if [[ "$ALLOWED" == '["*"]' ]]; then
  echo -e "${GREEN}PASS: Agent '$AGENT' allowed in state $CURRENT_STATE (wildcard)${NC}"
  exit 0
fi

ALLOWED_LIST=$(echo "$ALLOWED" | jq -r '.[]')
IS_ALLOWED=false

while IFS= read -r allowed_state; do
  if [[ "$allowed_state" == "$CURRENT_STATE" ]]; then
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

# ─── Blast Radius Check ─────────────────────────────────────────────────────
if [[ -n "$BLAST_RADIUS" ]]; then
  if [[ -z "$CONTRACT" || ! -f "$CONTRACT" ]]; then
    echo -e "${YELLOW}WARN: Cannot check blast radius: no contract file available${NC}"
  else
    acknowledged=$(jq -r '.score.governance.blast_radius_acknowledged // false' "$CONTRACT" 2>/dev/null || echo "false")

    if [[ "$acknowledged" != "true" ]]; then
      echo -e "${YELLOW}WARN: Blast radius $BLAST_RADIUS not acknowledged in contract.score.governance.blast_radius_acknowledged${NC}"
      echo -e "${YELLOW}  Run ctx_impact to assess blast radius, then set blast_radius_acknowledged=true in contract${NC}"
    else
      echo -e "${GREEN}PASS: Blast radius $BLAST_RADIUS acknowledged in contract${NC}"
    fi
  fi
fi
