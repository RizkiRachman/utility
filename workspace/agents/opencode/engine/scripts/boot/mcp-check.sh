#!/bin/sh
# boot/mcp-check.sh — MCP readiness preflight gate (sourced by entrypoint.sh)
#
# Probes every enabled `local` MCP server from the OpenCode config with a
# JSON-RPC `initialize` handshake so a dead MCP is detected at boot instead
# of mid-session. Pure POSIX sh: sourced (not executed) by the /bin/sh
# entrypoint, so no bashisms.
#
# Env consumed (defaults live in entrypoint.sh):
#   MCP_CHECK_ENABLED  true|false  enable the preflight (default: true)
#   MCP_CHECK_TIMEOUT  seconds     per-server timeout (default: 20)
#   MCP_CHECK_STRICT   true|false  exit 1 if any server is not ready (default: false)
#   MCP_CHECK_CONFIG   path        opencode config to read servers from
#
# Function body moved verbatim from entrypoint.sh (mcp_check_servers).

mcp_check_servers() {
  if [ "$MCP_CHECK_ENABLED" != "true" ]; then
    echo "[entrypoint] MCP readiness checks disabled"
    return 0
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo "[entrypoint] WARNING: jq not found; skipping MCP readiness checks" >&2
    return 0
  fi

  if [ ! -f "$MCP_CHECK_CONFIG" ]; then
    echo "[entrypoint] WARNING: config not found ($MCP_CHECK_CONFIG); skipping MCP readiness checks" >&2
    return 0
  fi

  init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"opencode-preflight","version":"1.0"}}}'

  names=$(jq -r 'def servers: ((.mcp.servers // .mcp) // {}); servers | to_entries[] | select(.value.type == "local") | select((.value.disabled // false) != true) | select((.value.enabled // true) != false) | .key' "$MCP_CHECK_CONFIG" 2>/dev/null || true)

  if [ -z "$names" ]; then
    echo "[entrypoint] no enabled local MCP servers to check"
    return 0
  fi

  echo "[entrypoint] checking MCP servers (timeout ${MCP_CHECK_TIMEOUT}s)..."

  failures=0
  total=0

  for name in $names; do
    total=$((total + 1))

    # Works for both V1 (.mcp.<name>) and V2 (.mcp.servers.<name>) shapes.
    cmd=$(jq -r --arg n "$name" '((.mcp.servers // .mcp) // {})[$n].command | @sh' "$MCP_CHECK_CONFIG")

    if ! eval "set -- $cmd"; then
      echo "[entrypoint]   FAIL  $name — malformed command in config" >&2
      failures=$((failures + 1))
      continue
    fi

    bin="$1"

    if ! command -v "$bin" >/dev/null 2>&1; then
      echo "[entrypoint]   FAIL  $name — executable '$bin' not found" >&2
      failures=$((failures + 1))
      continue
    fi

    response=$(printf '%s\n' "$init" | timeout -k 5 "$MCP_CHECK_TIMEOUT" "$@" 2>/dev/null || true)

    if printf '%s' "$response" | grep -q '"result"'; then
      echo "[entrypoint]   OK    $name — connected"
    else
      echo "[entrypoint]   FAIL  $name — no initialize response within ${MCP_CHECK_TIMEOUT}s" >&2
      failures=$((failures + 1))
    fi
  done

  if [ "$failures" -gt 0 ]; then
    echo "[entrypoint] MCP readiness: $((total - failures))/$total ready" >&2
    if [ "$MCP_CHECK_STRICT" = "true" ]; then
      echo "[entrypoint] ERROR: $failures MCP server(s) not ready (MCP_CHECK_STRICT=true)" >&2
      exit 1
    fi
    echo "[entrypoint] WARNING: continuing with $failures MCP server(s) unavailable" >&2
  else
    echo "[entrypoint] MCP readiness: $total/$total ready"
  fi
}
