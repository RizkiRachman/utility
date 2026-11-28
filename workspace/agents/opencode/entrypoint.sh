#!/bin/sh

set -eu

# Web uploads stage into /tmp/opencode/uploads. The image bakes /tmp/opencode
# node-owned; this guard re-creates it if absent (no-op if root-owned).
mkdir -p /tmp/opencode/uploads 2>/dev/null || true

# -----------------------------------------------------------------------------
# Session state seeding (D16/P2-12)
#
# The workflow engine project-root session/ (the container global session dir
# under /home/node/workspace) must exist before agents run: contract.json
# seeded from the engine contract template, state.md from its example, plus
# the archive dir. Idempotent: existing files are never overwritten.
# -----------------------------------------------------------------------------
SESSION_DIR="${OPENCODE_SESSION_DIR:-/home/node/workspace/session}"
# Seeding is best-effort (M6): an unwritable session dir must warn and skip,
# not crash-loop the container under set -eu. Healing is per-item (L6): a
# pre-existing contract.json does not imply archive/ or state.md exist, so
# each is (re-)created on its own when missing.
if ! mkdir -p "$SESSION_DIR" 2>/dev/null; then
  echo "[entrypoint] WARN: session dir not writable; skipping seeding" >&2
else
  seeded=0
  # L1: a dangling symlink at the target path makes cp follow it and write
  # to the (missing) link target instead of seeding the real file; drop the
  # symlink so the guard below seeds an actual file.
  if [ -L "$SESSION_DIR/contract.json" ]; then
    rm -f "$SESSION_DIR/contract.json"
  fi
  if [ ! -f "$SESSION_DIR/contract.json" ]; then
    if [ -f /opt/engine/contract/contract.template.json ]; then
      if cp /opt/engine/contract/contract.template.json "$SESSION_DIR/contract.json" 2>/dev/null; then
        seeded=1
      else
        echo "[entrypoint] WARN: could not copy contract template; skipping contract.json seeding" >&2
      fi
    else
      echo "[entrypoint] WARN: engine contract template not found; session/contract.json not seeded" >&2
    fi
  fi
  if [ ! -d "$SESSION_DIR/archive" ] && ! mkdir -p "$SESSION_DIR/archive" 2>/dev/null; then
    echo "[entrypoint] WARN: could not create $SESSION_DIR/archive" >&2
  fi
  # Same L1 dangling-symlink guard for state.md.
  if [ -L "$SESSION_DIR/state.md" ]; then
    rm -f "$SESSION_DIR/state.md"
  fi
  if [ ! -f "$SESSION_DIR/state.md" ] && [ -f /opt/engine/contract/state.template.md ]; then
    if cp /opt/engine/contract/state.template.md "$SESSION_DIR/state.md" 2>/dev/null; then
      seeded=1
    else
      echo "[entrypoint] WARN: could not copy state template; skipping state.md seeding" >&2
    fi
  fi
  if [ "$seeded" -eq 1 ]; then
    echo "[entrypoint] session state seeded at $SESSION_DIR"
  else
    echo "[entrypoint] session state ensured at $SESSION_DIR"
  fi
fi

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

# -----------------------------------------------------------------------------
# Server exposure preflight (S5/P2-11)
#
# OPENCODE_DEPLOY_MODE:
#   dev (default): current behavior - empty OPENCODE_SERVER_PASSWORD is
#     allowed; the server accepts unauthenticated peers on its port.
#   production: require OPENCODE_SERVER_PASSWORD, or an explicit
#     OPENCODE_BIND_LOCALHOST=1 to accept the loopback-only trade-off.
#     Anything else fails fast BEFORE MCP checks and server start.
# -----------------------------------------------------------------------------
OPENCODE_DEPLOY_MODE="${OPENCODE_DEPLOY_MODE:-dev}"
# Strict validation (fail closed, sec-L3): anything outside dev|production is
# a config error, not a silent fallback to dev.
case "$OPENCODE_DEPLOY_MODE" in
  dev|production) : ;;
  *)
    echo "[entrypoint] FATAL: OPENCODE_DEPLOY_MODE must be 'dev' or 'production' (got '$OPENCODE_DEPLOY_MODE')" >&2
    exit 1
    ;;
esac
if [ "$OPENCODE_DEPLOY_MODE" = "production" ]; then
  if [ -z "${OPENCODE_SERVER_PASSWORD:-}" ] && [ "${OPENCODE_BIND_LOCALHOST:-0}" != "1" ]; then
    echo "[entrypoint] FATAL: production mode requires OPENCODE_SERVER_PASSWORD or OPENCODE_BIND_LOCALHOST=1" >&2
    exit 1
  fi
fi

# Launch binding (S5/P2-11, implements OPENCODE_BIND_LOCALHOST): production +
# OPENCODE_BIND_LOCALHOST=1 binds the server to the container loopback instead
# of all interfaces. Only meaningful if the operator ALSO publishes the host
# port on loopback - add to the compose service (default publishes host
# loopback already):
#   ports: ["[IP_ADDRESS]:4096:4096"]   # loopback-scoped publish example
BIND_HOST=0.0.0.0
if [ "$OPENCODE_DEPLOY_MODE" = "production" ] && [ "${OPENCODE_BIND_LOCALHOST:-0}" = "1" ]; then
  BIND_HOST=127.0.0.1
  echo "[entrypoint] OPENCODE_BIND_LOCALHOST=1: binding $BIND_HOST - operator must also map host ports on loopback (ports: [\"127.0.0.1:4096:4096\"])"
fi

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
# optional ones (falkordb) only warn.

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
  echo "[entrypoint] starting: opencode serve --hostname $BIND_HOST --port 4096"
  exec opencode serve --hostname "$BIND_HOST" --port 4096
elif opencode web --help >/dev/null 2>&1; then
  echo "[entrypoint] starting: opencode web --hostname $BIND_HOST --port 4096"
  exec opencode web --hostname "$BIND_HOST" --port 4096
else
  echo "[entrypoint] WARN: neither serve nor web accepted; falling back to bare serve" >&2
  exec opencode serve
fi
