#!/bin/sh

set -eu

# Web uploads stage into /tmp/opencode/uploads. The image bakes /tmp/opencode
# node-owned; this guard re-creates it if absent (no-op if root-owned).
mkdir -p /tmp/opencode/uploads 2>/dev/null || true

# -----------------------------------------------------------------------------
# OpenCode authentication
# -----------------------------------------------------------------------------

OPENCODE_AUTH_REQUIRED="${OPENCODE_AUTH_REQUIRED:-true}"
OPENCODE_AUTH_DIR="${OPENCODE_AUTH_DIR:-$HOME/.local/share/opencode}"
OPENCODE_AUTH_FILE="${OPENCODE_AUTH_FILE:-$OPENCODE_AUTH_DIR/auth.json}"

configure_opencode_auth() {
  if [ -z "${OPENCODE_API_KEY:-}" ]; then
    if [ "$OPENCODE_AUTH_REQUIRED" = "true" ]; then
      echo "[entrypoint] ERROR: OPENCODE_API_KEY is required" >&2
      exit 1
    fi

    echo "[entrypoint] OPENCODE_API_KEY is not set; skipping authentication"
    return
  fi

  if ! command -v node >/dev/null 2>&1; then
    echo "[entrypoint] ERROR: node executable not found" >&2
    exit 1
  fi

  mkdir -p "$OPENCODE_AUTH_DIR"
  chmod 700 "$OPENCODE_AUTH_DIR"

  export OPENCODE_AUTH_FILE

  node <<'NODE'
const fs = require("fs");
const path = require("path");

const authFile = process.env.OPENCODE_AUTH_FILE;
const apiKey = process.env.OPENCODE_API_KEY;

if (!authFile) {
  console.error("[entrypoint] ERROR: OPENCODE_AUTH_FILE is missing");
  process.exit(1);
}

if (!apiKey) {
  console.error("[entrypoint] ERROR: OPENCODE_API_KEY is missing");
  process.exit(1);
}

let auth = {};

if (fs.existsSync(authFile)) {
  try {
    const content = fs.readFileSync(authFile, "utf8").trim();

    if (content) {
      auth = JSON.parse(content);
    }
  } catch (error) {
    console.error(
      `[entrypoint] ERROR: cannot parse ${authFile}: ${error.message}`
    );
    process.exit(1);
  }
}

if (
  auth.opencode &&
  auth.opencode.type === "api" &&
  auth.opencode.key === apiKey
) {
  console.log("[entrypoint] OpenCode authentication already configured");
  process.exit(0);
}

auth.opencode = {
  type: "api",
  key: apiKey
};

fs.mkdirSync(path.dirname(authFile), {
  recursive: true,
  mode: 0o700
});

const temporaryFile = `${authFile}.tmp`;

fs.writeFileSync(
  temporaryFile,
  `${JSON.stringify(auth, null, 2)}\n`,
  {
    encoding: "utf8",
    mode: 0o600
  }
);

fs.renameSync(temporaryFile, authFile);
fs.chmodSync(authFile, 0o600);

console.log("[entrypoint] OpenCode authentication configured");
NODE
}

configure_opencode_auth

# OpenCode reads the credential from auth.json.
# Remove the original token from the environment inherited by plugins and MCPs.
unset OPENCODE_API_KEY

# -----------------------------------------------------------------------------
# MCP readiness checks
# -----------------------------------------------------------------------------
#
# OpenCode launches every `local` MCP server from opencode.json as a stdio
# process. Before starting OpenCode, probe each enabled server with a JSON-RPC
# `initialize` handshake so a dead MCP is detected at boot instead of
# mid-session.
#
# Env:
#   MCP_CHECK_ENABLED          true|false  enable the preflight (default: true)
#   MCP_CHECK_TIMEOUT          seconds     per-server timeout (default: 20)
#   MCP_CHECK_STRICT           true|false  exit 1 if ANY server is not ready (default: false)
#   MCP_CHECK_BUILTIN_STRICT   true|false  exit 1 if a built-in server is not ready (default: true)
#
# Built-in servers (lean-ctx, context7, fetch, rag) are strict by default;
# optional ones (openui) only warn.

MCP_CHECK_ENABLED="${MCP_CHECK_ENABLED:-true}"
MCP_CHECK_TIMEOUT="${MCP_CHECK_TIMEOUT:-20}"
MCP_CHECK_STRICT="${MCP_CHECK_STRICT:-false}"
MCP_CHECK_BUILTIN_STRICT="${MCP_CHECK_BUILTIN_STRICT:-true}"
MCP_CHECK_CONFIG="${OPENCODE_CONFIG:-$HOME/.config/opencode/opencode.json}"

# Function body lives in scripts/boot/mcp-check.sh; source it conditionally so a
# missing engine degrades to a skip, matching the in-body fallback semantics
# (warn + continue, never fail the boot chain).
if [ -f /opt/engine/scripts/boot/mcp-check.sh ]; then
  . /opt/engine/scripts/boot/mcp-check.sh
  mcp_check_servers
else
  echo "[entrypoint] WARNING: /opt/engine/scripts/boot/mcp-check.sh not found; skipping MCP readiness checks" >&2
fi

# -----------------------------------------------------------------------------
# Engine boot self-check
# -----------------------------------------------------------------------------
#
# Optional preflight that validates the bundled workflow-state-engine before
# OpenCode starts, using the same scripts a developer would run by hand.
#
# Env:
#   ENGINE_BOOT_CHECK    true|false  enable the self-check (default: false)
#   ENGINE_BOOT_STRICT   true|false  exit 1 if any check fails (default: false)
#   ENGINE_BOOT_TIMEOUT  seconds     per-check timeout (default: 30)

ENGINE_BOOT_CHECK="${ENGINE_BOOT_CHECK:-false}"
ENGINE_BOOT_STRICT="${ENGINE_BOOT_STRICT:-false}"
ENGINE_BOOT_TIMEOUT="${ENGINE_BOOT_TIMEOUT:-30}"

# Function body lives in scripts/boot/engine-check.sh (moved verbatim); source
# it conditionally. The in-body /opt/engine guard is preserved; this elif only
# covers the module file itself missing (same warning text as the in-body guard).
if [ -f /opt/engine/scripts/boot/engine-check.sh ]; then
  . /opt/engine/scripts/boot/engine-check.sh
  engine_boot_checks
elif [ "$ENGINE_BOOT_CHECK" = "true" ]; then
  echo "[entrypoint] WARNING: /opt/engine not found; skipping engine boot checks" >&2
fi

# -----------------------------------------------------------------------------
# Start OpenCode
# -----------------------------------------------------------------------------
#
# v2 CLI subcommands/flags are not fully verified yet; probe each launch form
# with --help before exec so an unsupported flag set degrades gracefully
# instead of crash-looping the container.

if opencode serve --help >/dev/null 2>&1; then
  echo "[entrypoint] starting: opencode serve --hostname 0.0.0.0 --port 4096"
  exec opencode serve --hostname 0.0.0.0 --port 4096
elif opencode web --help >/dev/null 2>&1; then
  echo "[entrypoint] starting: opencode web --hostname 0.0.0.0 --port 4096"
  exec opencode web --hostname 0.0.0.0 --port 4096
else
  echo "[entrypoint] WARN: neither serve nor web accepted; falling back to bare serve" >&2
  exec opencode serve
fi
