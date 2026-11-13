#!/bin/sh
# boot/mcp-check.sh - MCP readiness preflight gate (sourced by entrypoint.sh)
#
# Probes every enabled `local` MCP server from the OpenCode config with a
# JSON-RPC `initialize` handshake so a dead MCP is detected at boot instead
# of mid-session. Pure POSIX sh: sourced (not executed) by the /bin/sh
# entrypoint, so no bashisms.
#
# The baked surface is deny-first: the built-in servers (lean-ctx, context7,
# fetch, rag, cocoindex-code) ship with the image and must answer or the boot
# fails; optional servers (openui) only warn.
#
# Env consumed (defaults live in entrypoint.sh):
#   MCP_CHECK_ENABLED         true|false  enable the preflight (default: true)
#   MCP_CHECK_TIMEOUT         seconds     per-server timeout (default: 20)
#   MCP_CHECK_STRICT          true|false  exit 1 on ANY server failure (default: false)
#   MCP_CHECK_BUILTIN_STRICT  true|false  exit 1 when a built-in server fails (default: true)
#   MCP_CHECK_CONFIG          path        opencode config to read servers from
#   MCP_CHECK_SKILLS_MANIFEST path        baked skills manifest (default: <engine-root>/skills.json)
#   MCP_CHECK_SKILLS_DIR      dir         shipped skill directories (default: /opt/engine/skills)
#   MCP_CHECK_ENGINE_ROOT     dir         engine root (default: /opt/engine)
#
# mcp_check_servers originated in entrypoint.sh; strictness and the asset
# assertions were added with the bake manifest.

# Built-in servers ship with the image and must answer; anything else is
# optional and warn-only. Space-separated, matched exactly.
#
# cocoindex-code counts as built-in: the `ccc` wheel is baked into the image and
# the Dockerfile hard-fails the build when it is missing, so a boot without it
# means a broken image. Deny-first is correct here - the JSON-RPC initialize
# handshake above proves the server answers before boot depends on it.
MCP_CHECK_BUILTIN="${MCP_CHECK_BUILTIN:-lean-ctx context7 fetch rag cocoindex-code}"

# Defensive defaults so the module also works when sourced standalone (the
# entrypoint normally sets all of these before sourcing).
MCP_CHECK_ENABLED="${MCP_CHECK_ENABLED:-true}"
MCP_CHECK_TIMEOUT="${MCP_CHECK_TIMEOUT:-20}"
MCP_CHECK_STRICT="${MCP_CHECK_STRICT:-false}"
MCP_CHECK_CONFIG="${MCP_CHECK_CONFIG:-${HOME:-/home/node}/.config/opencode/opencode.json}"

mcp_is_builtin() {
  case " $MCP_CHECK_BUILTIN " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# Cheap post-server assertions: the baked skills manifest matches the shipped
# skill directories, and the vendored firecrawl plugin is present.
#
# Criticality: a manifest count mismatch means the image shipped an inconsistent
# skill surface, so it counts as a boot failure. A missing manifest file and a
# missing plugin directory only warn (older images, partial dev trees).
# Failures are accumulated in ASSET_FAILURES and reported by the caller.
mcp_check_assets() {
  engine_root="${MCP_CHECK_ENGINE_ROOT:-/opt/engine}"
  manifest="${MCP_CHECK_SKILLS_MANIFEST:-$engine_root/skills.json}"
  skills_dir="${MCP_CHECK_SKILLS_DIR:-$engine_root/skills}"

  ASSET_FAILURES=0

  if [ ! -f "$manifest" ]; then
    echo "[entrypoint]   WARN  skills manifest missing ($manifest)" >&2
  else
    manifest_count=$(jq -r '.count // empty' "$manifest" 2>/dev/null || true)
    dir_count=0
    for skill_md in "$skills_dir"/*/SKILL.md; do
      if [ -f "$skill_md" ]; then
        dir_count=$((dir_count + 1))
      fi
    done
    if [ -z "$manifest_count" ]; then
      echo "[entrypoint]   WARN  skills manifest has no count ($manifest)" >&2
    elif [ "$manifest_count" != "$dir_count" ]; then
      echo "[entrypoint]   FAIL  skills manifest count $manifest_count != $dir_count skill dirs" >&2
      ASSET_FAILURES=$((ASSET_FAILURES + 1))
    else
      echo "[entrypoint]   OK    skills manifest: $manifest_count skills"
    fi
  fi

  if [ -d "$engine_root/plugins/opencode-firecrawl" ]; then
    echo "[entrypoint]   OK    firecrawl plugin present"
  else
    echo "[entrypoint]   WARN  firecrawl plugin missing ($engine_root/plugins/opencode-firecrawl)" >&2
  fi
}

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
    mcp_check_assets
    if [ "${ASSET_FAILURES:-0}" -gt 0 ]; then
      echo "[entrypoint] ERROR: baked asset check failed (skills manifest count mismatch)" >&2
      exit 1
    fi
    return 0
  fi

  echo "[entrypoint] checking MCP servers (timeout ${MCP_CHECK_TIMEOUT}s)..."

  failures=0
  critical=0
  total=0

  for name in $names; do
    total=$((total + 1))

    # Works for both V1 (.mcp.<name>) and V2 (.mcp.servers.<name>) shapes.
    cmd=$(jq -r --arg n "$name" '((.mcp.servers // .mcp) // {})[$n].command | @sh' "$MCP_CHECK_CONFIG")

    if ! eval "set -- $cmd"; then
      echo "[entrypoint]   FAIL  $name: malformed command in config" >&2
      failures=$((failures + 1))
      if mcp_is_builtin "$name"; then critical=$((critical + 1)); fi
      continue
    fi

    bin="$1"

    if ! command -v "$bin" >/dev/null 2>&1; then
      echo "[entrypoint]   FAIL  $name: executable '$bin' not found" >&2
      failures=$((failures + 1))
      if mcp_is_builtin "$name"; then critical=$((critical + 1)); fi
      continue
    fi

    response=$(printf '%s\n' "$init" | timeout -k 5 "$MCP_CHECK_TIMEOUT" "$@" 2>/dev/null || true)

    if printf '%s' "$response" | grep -q '"result"'; then
      echo "[entrypoint]   OK    $name: connected"
    else
      echo "[entrypoint]   FAIL  $name: no initialize response within ${MCP_CHECK_TIMEOUT}s" >&2
      failures=$((failures + 1))
      if mcp_is_builtin "$name"; then critical=$((critical + 1)); fi
    fi
  done

  mcp_check_assets

  if [ "$failures" -gt 0 ]; then
    echo "[entrypoint] MCP readiness: $((total - failures))/$total ready" >&2
    if [ "$MCP_CHECK_STRICT" = "true" ]; then
      echo "[entrypoint] ERROR: $failures MCP server(s) not ready (MCP_CHECK_STRICT=true)" >&2
      exit 1
    fi
    if [ "$critical" -gt 0 ] && [ "${MCP_CHECK_BUILTIN_STRICT:-true}" != "false" ]; then
      echo "[entrypoint] ERROR: $critical built-in MCP server(s) not ready (MCP_CHECK_BUILTIN_STRICT)" >&2
      exit 1
    fi
    echo "[entrypoint] WARNING: continuing with $failures MCP server(s) unavailable" >&2
  else
    echo "[entrypoint] MCP readiness: $total/$total ready"
  fi

  if [ "${ASSET_FAILURES:-0}" -gt 0 ]; then
    echo "[entrypoint] ERROR: baked asset check failed (skills manifest count mismatch)" >&2
    exit 1
  fi
}
