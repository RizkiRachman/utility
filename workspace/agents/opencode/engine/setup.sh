#!/usr/bin/env bash
# setup.sh — Create .opencode/ symlinks for flat project structure
# Run once on fresh clone: bash setup.sh
set -euo pipefail

# ── Pre-flight checks ──────────────────────────────────────────
echo "Running pre-flight checks..."
FAILED=0

# Bash >= 4 (for associative arrays used by some scripts)
if (( BASH_VERSINFO[0] < 4 )); then
  echo "ERROR: bash >= 4 required (found $BASH_VERSION). Install bash 4+ and re-run."
  FAILED=1
fi

# Node.js (required for OpenCode tooling)
if ! command -v node &>/dev/null; then
  echo "WARNING: node not found. OpenCode tooling may not work."
  echo "  Install from https://nodejs.org/ or via package manager."
fi

# lean-ctx (recommended for file management)
if ! command -v lean-ctx &>/dev/null; then
  echo "WARNING: lean-ctx not found. Some toolkit features will be unavailable."
  echo "  Install from: https://github.com/yvgude/lean-ctx"
fi

if [ "$FAILED" -eq 1 ]; then
  echo "Pre-flight checks FAILED. Fix errors above and re-run."
  exit 1
fi
echo "Pre-flight checks passed."
# ── End pre-flight checks ──────────────────────────────────────

echo ""
echo "── Tool Verification ──────────────────────────────────────"
source "$(dirname "$0")/scripts/check-mcp.sh" || FAILED=1
source "$(dirname "$0")/scripts/check-plugins.sh" || FAILED=1
echo "────────────────────────────────────────────────────────────"

if [ "$FAILED" -eq 1 ]; then
  echo ""
  echo "=============================="
  echo "  MISSING MANDATORY TOOLS"
  echo "=============================="
  echo "  Install the missing tools listed above and re-run setup.sh."
  exit 1
fi

echo ""

cd "$(pwd)"
echo "Creating .opencode/ symlinks..."
mkdir -p .opencode

ln -sfn ../agents   .opencode/agents
ln -sfn ../skills   .opencode/skills
ln -sfn ../rules    .opencode/rules
ln -sfn ../contract .opencode/orchestration
ln -sfn ../usage    .opencode/usage
ln -sfn ../agent.md .opencode/AGENTS.md

# ── Post-install validation ────────────────────────────────────
echo "Validating symlinks..."
VALIDATION_FAILED=0

# Expected symlinks: target -> source
declare -A SYMLINKS=(
  [".opencode/agents"]="../agents"
  [".opencode/skills"]="../skills"
  [".opencode/rules"]="../rules"
  [".opencode/orchestration"]="../contract"
  [".opencode/usage"]="../usage"
  [".opencode/AGENTS.md"]="../agent.md"
)

for target in "${!SYMLINKS[@]}"; do
  if [ ! -L "$target" ]; then
    echo "FAIL: $target is not a symlink"
    VALIDATION_FAILED=1
  elif [ "$(readlink "$target")" != "${SYMLINKS[$target]}" ]; then
    echo "FAIL: $target points to $(readlink "$target") (expected ${SYMLINKS[$target]})"
    VALIDATION_FAILED=1
  else
    echo "  OK: $target -> $(readlink "$target")"
  fi
done

if [ "$VALIDATION_FAILED" -eq 1 ]; then
  echo ""
  echo "WARNING: Some symlinks are incorrect or missing. Re-run setup.sh or fix manually."
  echo "Expected layout:"
  echo "  .opencode/agents        -> ../agents"
  echo "  .opencode/skills        -> ../skills"
  echo "  .opencode/rules         -> ../rules"
  echo "  .opencode/orchestration -> ../contract"
  echo "  .opencode/usage         -> ../usage"
  echo "  .opencode/AGENTS.md     -> ../agent.md"
  exit 1
fi

echo "All symlinks valid."
echo ""
echo "Setup complete. The toolkit is ready."
