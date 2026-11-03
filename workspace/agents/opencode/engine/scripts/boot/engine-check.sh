#!/bin/sh
# boot/engine-check.sh — Engine boot self-check gate (sourced by entrypoint.sh)
#
# Optional preflight that validates the bundled workflow-state-engine before
# OpenCode starts, using the same scripts a developer would run by hand
# (validate-contract.sh --score, check-plugins.sh). Pure POSIX sh: sourced
# (not executed) by the /bin/sh entrypoint, so no bashisms.
#
# Env consumed (defaults live in entrypoint.sh):
#   ENGINE_BOOT_CHECK    true|false  enable the self-check (default: false)
#   ENGINE_BOOT_STRICT   true|false  exit 1 if any check fails (default: false)
#   ENGINE_BOOT_TIMEOUT  seconds     per-check timeout (default: 30)
#   MCP_CHECK_CONFIG     path        config passed to check-plugins.sh
#
# Function body moved verbatim from entrypoint.sh (engine_boot_checks).

engine_boot_checks() {
  if [ "$ENGINE_BOOT_CHECK" != "true" ]; then
    echo "[entrypoint] engine boot checks disabled"
    return 0
  fi

  if [ ! -d /opt/engine/scripts ]; then
    echo "[entrypoint] WARNING: /opt/engine not found; skipping engine boot checks" >&2
    return 0
  fi

  failures=0

  echo "[entrypoint] engine boot: validating contract template (timeout ${ENGINE_BOOT_TIMEOUT}s)..."
  if timeout "$ENGINE_BOOT_TIMEOUT" bash /opt/engine/scripts/validate-contract.sh --file /opt/engine/contract/contract.template.json --score; then
    echo "[entrypoint]   OK    contract template"
  else
    echo "[entrypoint]   FAIL  contract template" >&2
    failures=$((failures + 1))
  fi

  echo "[entrypoint] engine boot: checking plugins (config $MCP_CHECK_CONFIG)..."
  if timeout "$ENGINE_BOOT_TIMEOUT" bash /opt/engine/scripts/check-plugins.sh "$MCP_CHECK_CONFIG"; then
    echo "[entrypoint]   OK    plugins"
  else
    echo "[entrypoint]   FAIL  plugins" >&2
    failures=$((failures + 1))
  fi

  if [ "$failures" -gt 0 ]; then
    if [ "$ENGINE_BOOT_STRICT" = "true" ]; then
      echo "[entrypoint] ERROR: $failures engine boot check(s) failed (ENGINE_BOOT_STRICT=true)" >&2
      exit 1
    fi
    echo "[entrypoint] WARNING: continuing with $failures engine boot check(s) failed" >&2
  else
    echo "[entrypoint] engine boot: all checks passed"
  fi
}
