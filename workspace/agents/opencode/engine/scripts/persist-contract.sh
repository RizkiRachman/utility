#!/usr/bin/env bash
# =============================================================================
# persist-contract.sh — Atomic Envelope Persistence
#
# Atomically writes a contract.json file using temp-file + rename pattern.
# Prevents partial/corrupt writes that could break the orchestration state.
#
# Usage:
#   ./scripts/persist-contract.sh --file path [--score] [--validate] [--verbose]
#
# Options:
#   --file PATH    Target file (default: $PROJECT_DIR/session/contract.json, session-derived)
#   --score N      Score value to inject before writing (optional)
#   --validate     Run validate-contract.sh on the file after write
#   --verbose      Verbose output
#
# Exit codes:
#   0 = Write successful (and validation passed, if --validate)
#   1 = Validation failed (only with --validate)
#   2 = Write failed (temp file error, rename failed)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# Dynamic session-based default: live state is at session/contract.json
br=$(echo session 2>/dev/null || echo "main")
if [[ "$br" == "HEAD" ]]; then br="main"; fi
CONTRACT_FILE="$PROJECT_DIR/session/contract.json"
SCORE=""
RUN_VALIDATE=false
VERBOSE=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Atomically persist a contract envelope using temp-file + rename.

Options:
  --file PATH    Target file (default: $PROJECT_DIR/session/contract.json)
  --score N      Score value to inject before writing
  --validate     Run validate-contract.sh on the file after write
  --verbose      Verbose output
  --help         Show this message
EOF
    exit 0
}

# --- Parse args ------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --file) CONTRACT_FILE="$2"; shift 2 ;;
        --score) SCORE="$2"; shift 2 ;;
        --validate) RUN_VALIDATE=true; shift ;;
        --verbose) VERBOSE=true; shift ;;
        --help|-h) usage ;;
        *) echo "ERROR: Unknown option: $1" >&2; usage ;;
    esac
done

if [[ "$VERBOSE" == true ]]; then
    echo -e "${YELLOW}[INFO]${NC} Persisting: $CONTRACT_FILE"
fi

# --- Check input file exists -----------------------------------------------
if [[ ! -f "$CONTRACT_FILE" ]]; then
    echo "ERROR: Contract file not found: $CONTRACT_FILE" >&2
    exit 2
fi

# --- Validate JSON before writing ------------------------------------------
if ! python3 -c "
import json, sys
with open('$CONTRACT_FILE') as f:
    json.load(f)
sys.exit(0)
" 2>/dev/null; then
    echo "ERROR: Invalid JSON in $CONTRACT_FILE — aborting" >&2
    exit 2
fi

# --- Optionally inject score -----------------------------------------------
if [[ -n "$SCORE" ]]; then
    if [[ "$VERBOSE" == true ]]; then
        echo -e "${YELLOW}[INFO]${NC} Injecting score: $SCORE"
    fi
    python3 -c "
import json
with open('$CONTRACT_FILE') as f:
    data = json.load(f)
data['score'] = data.get('score', {})
data['score']['combined'] = $SCORE
verdict = 'PASS' if $SCORE >= 70 else ('RETRY' if $SCORE >= 50 else 'BLOCKED')
data['score']['verdict'] = verdict
with open('$CONTRACT_FILE', 'w') as f:
    json.dump(data, f, indent=2)
" 2>&1 || {
    echo "ERROR: Score injection failed" >&2
    exit 2
}
fi

# --- Step 1: Write to temp file --------------------------------------------
TEMP_FILE=$(mktemp /tmp/contract-persist-XXXXXX.json)
if [[ -z "$TEMP_FILE" ]]; then
    echo "ERROR: Failed to create temp file" >&2
    exit 2
fi

# Copy to temp
cp "$CONTRACT_FILE" "$TEMP_FILE"

# Verify temp file is valid JSON
if ! python3 -c "
import json
with open('$TEMP_FILE') as f:
    json.load(f)
" 2>/dev/null; then
    echo "ERROR: Temp file has invalid JSON — aborting" >&2
    rm -f "$TEMP_FILE"
    exit 2
fi

if [[ "$VERBOSE" == true ]]; then
    echo -e "${YELLOW}[INFO]${NC} Temp file: $TEMP_FILE (valid JSON)"
fi

# --- Step 2: Atomically rename --------------------------------------------
if ! mv "$TEMP_FILE" "$CONTRACT_FILE"; then
    echo "ERROR: Rename failed: $TEMP_FILE → $CONTRACT_FILE" >&2
    rm -f "$TEMP_FILE"
    exit 2
fi

if [[ "$VERBOSE" == true ]]; then
    echo -e "${GREEN}[PASS]${NC} Atomic write successful: $CONTRACT_FILE"
fi

# --- Step 3: Optional validation --------------------------------------------
if [[ "$RUN_VALIDATE" == true ]]; then
    if [[ "$VERBOSE" == true ]]; then
        echo -e "${YELLOW}[INFO]${NC} Running post-write validation..."
    fi
    SCORE_OUTPUT=$("$SCRIPT_DIR/validate-contract.sh" --file "$CONTRACT_FILE" --score 2>/dev/null || true)
    if [[ -z "$SCORE_OUTPUT" ]] || [[ "$SCORE_OUTPUT" == "0" ]]; then
        echo -e "${RED}[FAIL]${NC} Post-write validation failed" >&2
        exit 1
    fi
    if [[ "$VERBOSE" == true ]]; then
        echo -e "${GREEN}[PASS]${NC} Post-write validation passed (score: $SCORE_OUTPUT)"
    fi
fi

exit 0
