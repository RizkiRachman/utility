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
#   --validate     Validate the staged file before replacing the target
#   --verbose      Verbose output
#
# Exit codes:
#   0 = Write successful (and validation passed, if --validate)
#   1 = Validation failed before the target was replaced
#   2 = Write failed (temp file error, rename failed)
#
# Lock: holds an exclusive flock on <contract>.lock (fd 9) for its whole
# lifetime; every other envelope writer must take the same lock.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# N1: session state lives with the PROJECT, not the engine copy
source "${SCRIPT_DIR}/lib/paths.sh"
PROJECT_DIR="$(resolve_project_root "${SCRIPT_DIR}/..")"
CONTRACT_FILE="${PROJECT_DIR}/session/contract.json"
SCORE=""
FROM_FILE=""
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
  --from-file P  Install an already-prepared contract file atomically
  --score N      Score value to inject before writing
  --validate     Validate the staged file before replacing the target
  --verbose      Verbose output
  --help         Show this message
EOF
    exit 0
}

# --- Parse args ------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --file) CONTRACT_FILE="$2"; shift 2 ;;
        --from-file) FROM_FILE="$2"; shift 2 ;;
        --score) SCORE="$2"; shift 2 ;;
        --validate) RUN_VALIDATE=true; shift ;;
        --verbose) VERBOSE=true; shift ;;
        --help|-h) usage ;;
        *) echo "ERROR: Unknown option: $1" >&2; usage ;;
    esac
done

if [[ -n "$FROM_FILE" && -n "$SCORE" ]]; then
    echo "ERROR: --from-file and --score are mutually exclusive" >&2
    exit 2
fi

# Lock the selected contract, not the default path established before parsing.
# Group form keeps fd 2 alive when lock-file creation fails.
{ exec 9>"${CONTRACT_FILE}.lock"; } 2>/dev/null || true
flock 9 2>/dev/null || true

if [[ "$VERBOSE" == true ]]; then
    echo -e "${YELLOW}[INFO]${NC} Persisting: $CONTRACT_FILE"
fi

# --- Check input file exists -----------------------------------------------
if [[ -n "$FROM_FILE" && ! -f "$FROM_FILE" ]]; then
    echo "ERROR: --from-file source not found: $FROM_FILE" >&2
    exit 2
fi
if [[ -z "$FROM_FILE" && ! -f "$CONTRACT_FILE" ]]; then
    echo "ERROR: Contract file not found: $CONTRACT_FILE" >&2
    exit 2
fi

# --- Prepare a same-directory staging file --------------------------------
SOURCE_FILE="${FROM_FILE:-$CONTRACT_FILE}"
if ! TEMP_FILE=$(mktemp "${CONTRACT_FILE}.tmp.XXXXXX"); then
    echo "ERROR: Failed to create staging file beside $CONTRACT_FILE" >&2
    exit 2
fi
cleanup() {
    if [[ -n "${TEMP_FILE:-}" ]]; then
        rm -f -- "$TEMP_FILE"
    fi
}
trap cleanup EXIT

if [[ -n "$SCORE" ]]; then
    if [[ "$VERBOSE" == true ]]; then
        echo -e "${YELLOW}[INFO]${NC} Injecting score: $SCORE"
    fi
    if ! python3 - "$SOURCE_FILE" "$TEMP_FILE" "$SCORE" <<'PY'
import json
import math
import sys

source, target, raw_score = sys.argv[1:]
score = json.loads(raw_score)
if isinstance(score, bool) or not isinstance(score, (int, float)) or not math.isfinite(score):
    raise ValueError("score must be a finite JSON number")
with open(source) as stream:
    data = json.load(stream)
data["score"] = data.get("score") or {}
data["score"]["combined"] = score
data["score"]["verdict"] = "PASS" if score >= 70 else ("RETRY" if score >= 50 else "BLOCKED")
with open(target, "w") as stream:
    json.dump(data, stream, indent=2)
    stream.write("\n")
PY
    then
        echo "ERROR: Score injection failed" >&2
        exit 2
    fi
elif ! cp "$SOURCE_FILE" "$TEMP_FILE"; then
    echo "ERROR: Failed to stage contract from $SOURCE_FILE" >&2
    exit 2
fi

if ! python3 - "$TEMP_FILE" <<'PY'
import json
import sys

with open(sys.argv[1]) as stream:
    json.load(stream)
PY
then
    echo "ERROR: Staged contract is invalid JSON — aborting" >&2
    exit 2
fi

if [[ "$VERBOSE" == true ]]; then
    echo -e "${YELLOW}[INFO]${NC} Temp file: $TEMP_FILE (valid JSON)"
fi

# --- Validate before committing -------------------------------------------
if [[ "$RUN_VALIDATE" == true ]]; then
    if [[ "$VERBOSE" == true ]]; then
        echo -e "${YELLOW}[INFO]${NC} Validating staged contract..."
    fi
    SCORE_OUTPUT=$("$SCRIPT_DIR/validate-contract.sh" --file "$TEMP_FILE" --score 2>/dev/null || true)
    if [[ -z "$SCORE_OUTPUT" || "$SCORE_OUTPUT" == "0" ]]; then
        echo -e "${RED}[FAIL]${NC} Staged contract validation failed; target was not changed" >&2
        exit 1
    fi
    if [[ "$VERBOSE" == true ]]; then
        echo -e "${GREEN}[PASS]${NC} Staged contract validation passed (score: $SCORE_OUTPUT)"
    fi
fi

# --- Commit by same-filesystem rename -------------------------------------
if ! mv "$TEMP_FILE" "$CONTRACT_FILE"; then
    echo "ERROR: Rename failed: $TEMP_FILE → $CONTRACT_FILE" >&2
    exit 2
fi
TEMP_FILE=""

if [[ "$VERBOSE" == true ]]; then
    echo -e "${GREEN}[PASS]${NC} Atomic write successful: $CONTRACT_FILE"
fi

exit 0
