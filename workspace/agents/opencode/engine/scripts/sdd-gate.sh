#!/usr/bin/env bash
set -euo pipefail

# ─── Configuration ─────────────────────────────────────────────────────────
SCRIPT_NAME="$(basename "$0")"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ─── Usage ─────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
SDD (Spec-Driven Development) Gate — enforces spec approval before EXECUTE.

USAGE:
  $SCRIPT_NAME --file CONTRACT_JSON              Check current contract
  $SCRIPT_NAME --file CONTRACT_JSON --estimate N  Override time estimate (minutes)
  $SCRIPT_NAME --file CONTRACT_JSON --count-files  Just count files in scope
  $SCRIPT_NAME --dry-run
  $SCRIPT_NAME --help

GATES:
  File count    > 3 files in scope.included[]        → SDD required
  Boundary      Files cross dir boundaries (>1 dir)  → SDD required
  Time estimate > 30 minutes                         → SDD required

If SDD required, checks for approved spec (governance.mode=spec AND
outputs.architecture populated). Blocks with exit 1 if no spec found.

EXEMPTIONS (always pass):
  - Trivial bug fixes  (governance.mode == "fix" or clearly 1-line change)
  - Config-only changes (scope only under config/ or .github/)
  - Documentation-only  (all scope files end in .md)

EXAMPLES:
  $SCRIPT_NAME --file contract.json
  $SCRIPT_NAME --file contract.json --estimate 45
  $SCRIPT_NAME --file contract.json --count-files
  $SCRIPT_NAME --file session/my-feature/contract.json --dry-run
EOF
  exit 0
}

# ─── Help flag ─────────────────────────────────────────────────────────────
if [[ $# -eq 0 ]]; then
  usage
fi

# ─── Parse arguments ───────────────────────────────────────────────────────
CONTRACT=""
ESTIMATE=""
COUNT_FILES=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --file)
      CONTRACT="$2"
      shift 2
      ;;
    --estimate)
      ESTIMATE="$2"
      shift 2
      ;;
    --count-files)
      COUNT_FILES=true
      shift
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
      echo "Run '$SCRIPT_NAME --help' for usage." >&2
      exit 1
      ;;
  esac
done

# ─── Prerequisites ─────────────────────────────────────────────────────────
if ! command -v jq &>/dev/null; then
  echo -e "${RED}ERROR: jq is required but not installed${NC}" >&2
  exit 1
fi

# ─── Dry-run or count-files only ───────────────────────────────────────────
if [[ -z "$CONTRACT" && "$COUNT_FILES" == false ]]; then
  echo -e "${YELLOW}No --file specified. Use --dry-run to test? Run with --help for usage.${NC}" >&2
  exit 1
fi

if [[ "$COUNT_FILES" == true ]]; then
  if [[ -z "$CONTRACT" ]]; then
    echo -e "${RED}ERROR: --count-files requires --file CONTRACT_JSON${NC}" >&2
    exit 1
  fi
  if [[ ! -f "$CONTRACT" ]]; then
    echo -e "${RED}ERROR: Contract file not found: $CONTRACT${NC}" >&2
    exit 1
  fi
  FILES=$(jq -r '.scope.included[] // empty' "$CONTRACT" 2>/dev/null | wc -l | tr -d ' ')
  echo "Files in scope: $FILES"
  exit 0
fi

# ─── Read contract ─────────────────────────────────────────────────────────
if [[ -z "$CONTRACT" ]]; then
  echo -e "${RED}ERROR: --file CONTRACT_JSON is required${NC}" >&2
  exit 1
fi

if [[ ! -f "$CONTRACT" ]]; then
  echo -e "${RED}ERROR: Contract file not found: $CONTRACT${NC}" >&2
  exit 1
fi

# ─── Extract fields ────────────────────────────────────────────────────────
SCOPE_INCLUDED=$(jq -r '.scope.included // []' "$CONTRACT" 2>/dev/null)
SCOPE_EXCLUDED=$(jq -r '.scope.excluded // []' "$CONTRACT" 2>/dev/null)
OUTPUTS_PLAN=$(jq -r '.outputs.plan // ""' "$CONTRACT" 2>/dev/null)
OUTPUTS_ARCHITECTURE=$(jq -r '.outputs.architecture // ""' "$CONTRACT" 2>/dev/null)
GOVERNANCE_MODE=$(jq -r '.governance.mode // ""' "$CONTRACT" 2>/dev/null)

if $DRY_RUN; then
  echo -e "${BLUE}[DRY-RUN] Contract: $CONTRACT${NC}"
  echo -e "${BLUE}[DRY-RUN] Scope included: $(echo "$SCOPE_INCLUDED" | jq -c '.')${NC}"
  echo -e "${BLUE}[DRY-RUN] Governance mode: $GOVERNANCE_MODE${NC}"
  echo -e "${BLUE}[DRY-RUN] Architecture populated: $([[ -n "$OUTPUTS_ARCHITECTURE" && "$OUTPUTS_ARCHITECTURE" != "null" ]] && echo "yes" || echo "no")${NC}"
fi

# ─── Count files ────────────────────────────────────────────────────────────
FILE_COUNT=0
FILE_PATHS=()
while IFS= read -r line; do
  if [[ -n "$line" ]]; then
    FILE_PATHS+=("$line")
    ((FILE_COUNT++))
  fi
done < <(echo "$SCOPE_INCLUDED" | jq -r '.[] // empty' 2>/dev/null)

# ─── Detect config-only or doc-only exemptions ────────────────────────────
CONFIG_ONLY=true
DOC_ONLY=true

for f in "${FILE_PATHS[@]}"; do
  # Check config-only: every path must start with "config/" or ".github/"
  if [[ "$f" != config/* && "$f" != .github/* ]]; then
    CONFIG_ONLY=false
  fi
  # Check doc-only: every path must end in .md
  if [[ "$f" != *.md ]]; then
    DOC_ONLY=false
  fi
done

# If zero files, treat as no files to analyze — but can't be config-only or doc-only
if [[ "$FILE_COUNT" -eq 0 ]]; then
  CONFIG_ONLY=false
  DOC_ONLY=false
fi

# ─── Detect trivial fix exemption ─────────────────────────────────────────
TRIVIAL_FIX=false
if [[ "$GOVERNANCE_MODE" == "fix" ]]; then
  TRIVIAL_FIX=true
fi
# 1-line change heuristic: single file with short content — conservative,
# we treat governance.mode=="fix" as the reliable signal.

# ─── Exemption check ──────────────────────────────────────────────────────
IS_EXEMPT=false
EXEMPT_REASON=""

if [[ "$FILE_COUNT" -eq 0 ]]; then
  IS_EXEMPT=true
  EXEMPT_REASON="no scope files to change"
elif [[ "$GOVERNANCE_MODE" == "fix" ]]; then
  IS_EXEMPT=true
  EXEMPT_REASON="trivial bug fix (governance.mode=fix)"
elif [[ "$FILE_COUNT" -eq 1 && "$GOVERNANCE_MODE" == "fix" ]]; then
  IS_EXEMPT=true
  EXEMPT_REASON="single-file fix"
elif [[ "$CONFIG_ONLY" == true && "$FILE_COUNT" -gt 0 ]]; then
  IS_EXEMPT=true
  EXEMPT_REASON="config-only changes"
elif [[ "$DOC_ONLY" == true && "$FILE_COUNT" -gt 0 ]]; then
  IS_EXEMPT=true
  EXEMPT_REASON="documentation-only changes"
fi

# ─── Boundary crossing check ──────────────────────────────────────────────
BOUNDARY_CROSSING=false
UNIQUE_DIRS=()
for f in "${FILE_PATHS[@]}"; do
  dirname=$(dirname "$f")
  # Check if this dirname already seen
  found=false
  for d in "${UNIQUE_DIRS[@]}"; do
    if [[ "$d" == "$dirname" ]]; then
      found=true
      break
    fi
  done
  if [[ "$found" == false ]]; then
    UNIQUE_DIRS+=("$dirname")
  fi
done

if [[ ${#UNIQUE_DIRS[@]} -gt 1 ]]; then
  BOUNDARY_CROSSING=true
fi

UNIQUE_DIR_COUNT=${#UNIQUE_DIRS[@]}

# ─── Time estimate ────────────────────────────────────────────────────────
if [[ -n "$ESTIMATE" ]]; then
  TIME_ESTIMATE="$ESTIMATE"
elif [[ -n "$OUTPUTS_PLAN" && "$OUTPUTS_PLAN" != "null" ]]; then
  # Estimate from plan text length: 100 chars ~ 1 minute
  PLAN_LEN=${#OUTPUTS_PLAN}
  TIME_ESTIMATE=$(( (PLAN_LEN + 99) / 100 ))
  # Clamp minimum to 1
  if [[ "$TIME_ESTIMATE" -lt 1 ]]; then
    TIME_ESTIMATE=1
  fi
else
  # No plan available → conservative: assume 31 min
  TIME_ESTIMATE=31
fi

# ─── Gate evaluation ──────────────────────────────────────────────────────
SDD_REQUIRED=false
GATE_REASONS=()

# File count gate
if [[ "$FILE_COUNT" -gt 3 ]]; then
  SDD_REQUIRED=true
  GATE_REASONS+=("file count: $FILE_COUNT (threshold: 3)")
fi

# Boundary crossing gate
if [[ "$BOUNDARY_CROSSING" == true ]]; then
  SDD_REQUIRED=true
  GATE_REASONS+=("boundary crossing: $UNIQUE_DIR_COUNT directories")
fi

# Time estimate gate
if [[ "$TIME_ESTIMATE" -gt 30 ]]; then
  SDD_REQUIRED=true
  GATE_REASONS+=("time estimate: ${TIME_ESTIMATE}min (threshold: 30)")
fi

# ─── Apply exemption override ─────────────────────────────────────────────
if [[ "$IS_EXEMPT" == true ]]; then
  SDD_REQUIRED=false
fi

# ─── Check for spec ───────────────────────────────────────────────────────
SPEC_FOUND=false
if [[ "$GOVERNANCE_MODE" == "spec" ]]; then
  if [[ -n "$OUTPUTS_ARCHITECTURE" && "$OUTPUTS_ARCHITECTURE" != "null" && ${#OUTPUTS_ARCHITECTURE} -gt 50 ]]; then
    SPEC_FOUND=true
  fi
fi

# ─── Output ───────────────────────────────────────────────────────────────
BOUNDARY_DISPLAY="no"
if [[ "$BOUNDARY_CROSSING" == true ]]; then
  BOUNDARY_DISPLAY="yes"
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  $SCRIPT_NAME — SDD Gate Status"
echo "╚══════════════════════════════════════════════════════════════╝"

if [[ "$SDD_REQUIRED" == false ]] && [[ "$IS_EXEMPT" == false ]]; then
  echo -e "   ${GREEN}Files:${NC} $FILE_COUNT, ${GREEN}Boundary crossing:${NC} $BOUNDARY_DISPLAY, ${GREEN}Estimate:${NC} ${TIME_ESTIMATE}min"
  echo -e "   ${GREEN}SDD not required — below all thresholds${NC}"
  echo ""
  echo -e "${GREEN}✅ $SCRIPT_NAME — SDD Gate Status: PASS${NC}"
  exit 0

elif [[ "$SDD_REQUIRED" == false ]] && [[ "$IS_EXEMPT" == true ]]; then
  echo -e "   ${GREEN}Files:${NC} $FILE_COUNT, ${GREEN}Boundary crossing:${NC} $BOUNDARY_DISPLAY, ${GREEN}Estimate:${NC} ${TIME_ESTIMATE}min"
  echo -e "   ${GREEN}SDD exempt:${NC} $EXEMPT_REASON"
  echo ""
  echo -e "${GREEN}✅ $SCRIPT_NAME — SDD Gate Status: PASS${NC}"
  exit 0

elif [[ "$SDD_REQUIRED" == true ]] && [[ "$SPEC_FOUND" == true ]]; then
  REASONS=$(IFS="; " ; echo "${GATE_REASONS[*]}")
  echo -e "   ${YELLOW}Files:${NC} $FILE_COUNT, ${YELLOW}Boundary crossing:${NC} $BOUNDARY_DISPLAY, ${YELLOW}Estimate:${NC} ${TIME_ESTIMATE}min"
  echo -e "   ${YELLOW}Triggers:${NC} $REASONS"
  echo -e "   ${GREEN}SDD required. Spec found (governance.mode=spec, architecture populated)${NC}"
  echo ""
  echo -e "${GREEN}✅ $SCRIPT_NAME — SDD Gate Status: PASS${NC}"
  exit 0

elif [[ "$SDD_REQUIRED" == true ]] && [[ "$SPEC_FOUND" == false ]]; then
  REASONS=$(IFS="; " ; echo "${GATE_REASONS[*]}")
  echo -e "   ${RED}Files:${NC} $FILE_COUNT, ${RED}Boundary crossing:${NC} $BOUNDARY_DISPLAY, ${RED}Estimate:${NC} ${TIME_ESTIMATE}min"
  echo -e "   ${RED}Triggers:${NC} $REASONS"
  echo -e "   ${RED}SDD required but no approved spec found.${NC}"
  echo "   Run: @system-analyst with 'mode: spec' before EXECUTE delegation."
  echo "   Exemption check: not applicable (not trivial fix, config-only, or doc-only)"
  echo ""
  echo -e "${RED}⛔ $SCRIPT_NAME — SDD Gate Status: BLOCKED${NC}"
  exit 1
fi

# Fallback (should not reach here)
echo -e "${RED}ERROR: Unexpected state${NC}" >&2
exit 1