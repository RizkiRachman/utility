#!/bin/sh
# Populate the offline package store (pre-install/) used by the Docker build.
#
# pre-install/ is fully gitignored (except its .gitkeep files): its contents
# live only on the local disk / inside the workspace volume and are NEVER
# committed or pushed. The store is portable - copy the workspace to another
# machine and the store comes with it.
#
# Idempotent: every artifact follows the same skip-if-exists pattern - when
# its marker (tarball, wheel, binary, deb, clone dir, zip) is already in the
# store, the fetch is skipped, so re-runs fetch only what is missing. Root is
# required only for the apt section. Store sections: npm pip bin apt git dist.
#
# Version policy: latest at populate time - the STORE is the lockfile. The
# Dockerfile store-first tiers are glob-based (...-*.tgz / *-*.whl), so the
# store always governs offline installs; only the network fallbacks care about
# numbers, and those are now "latest" when the Dockerfile ARG is empty.
# The exact versions used by this run are written to pre-install/versions.lock.
# Env overrides (OPENCODE_VERSION=... sh populate-preinstall.sh) win and are
# the reproducibility escape hatch.
set -eu

# Versions - env-overridable. Empty here means "resolve latest below, after
# the CA-trust block" (resolution needs network + trusted corporate CAs).
OPENCODE_VERSION="${OPENCODE_VERSION:-}"
OPENCODE_ARCH="${OPENCODE_ARCH:-arm64}"  # @opencode/cli-linux-${OPENCODE_ARCH}
OPENCODE_PLATFORM_VERSION="${OPENCODE_PLATFORM_VERSION:-}"
CONTEXT7_VERSION="${CONTEXT7_VERSION:-}"
LEAN_CTX_VERSION="${LEAN_CTX_VERSION:-}"
MCP_VERSION="${MCP_VERSION:-}"
MCP_SERVER_FETCH_VERSION="${MCP_SERVER_FETCH_VERSION:-}"
COCOINDEX_CODE_VERSION="${COCOINDEX_CODE_VERSION:-}"
# @firecrawl/opencode runtime dependency + CLI companion (offline store pins)
ZOD_VERSION="${ZOD_VERSION:-}"
FIRECRAWL_CLI_VERSION="${FIRECRAWL_CLI_VERSION:-}"

STORE_DIR=$(cd "$(dirname "$0")" && pwd)/pre-install
mkdir -p "$STORE_DIR/npm" "$STORE_DIR/pip" "$STORE_DIR/bin" "$STORE_DIR/apt" \
  "$STORE_DIR/git" "$STORE_DIR/dist"

# Trust extra root CAs shipped in certs/ (corporate MITM proxies like Zscaler).
# The preinstall container mounts this repo dir at /repo, so /repo/certs is the
# committed certs/ folder. Needs root; warn-only so non-root runs still proceed.
ca_trusted=0
for crt in /repo/certs/*.crt; do
  if [ -e "$crt" ]; then
    if cp "$crt" /usr/local/share/ca-certificates/; then
      ca_trusted=1
    else
      echo "WARN: could not install CA $crt (need root) - proxied TLS hosts may fail" >&2
    fi
  fi
done
if [ "$ca_trusted" -eq 1 ]; then
  echo "==> trusting extra root CAs from certs/"
  update-ca-certificates >/dev/null 2>&1 || \
    echo "WARN: update-ca-certificates failed - proxied TLS hosts may fail" >&2
fi

# --------------------------------------------------------------------------
# version resolution - latest at populate time (env overrides win)
#
# Each resolver prints one version and exits non-zero on any failure, so the
# `|| VAR=""` chain below treats "no output" and "failed" the same way. The
# fallbacks are the previous default pins: a registry hiccup warns and keeps
# populating instead of aborting the store build.
# --------------------------------------------------------------------------
latest_npm() {   # $1 = package name
  npm view "$1" version 2>/dev/null
}

latest_pypi() {  # $1 = package name
  curl -fsSL "https://pypi.org/pypi/$1/json" 2>/dev/null | \
    python3 -c "import json,sys; print(json.load(sys.stdin)['info']['version'])" 2>/dev/null
}

latest_github() {  # $1 = owner/repo
  curl -fsSL "https://api.github.com/repos/$1/releases/latest" 2>/dev/null | \
    python3 -c "import json,sys; print(json.load(sys.stdin)['tag_name'].lstrip('v'))" 2>/dev/null
}

resolve_field() { # resolve_field <var> <package> <fallback> <resolver> <arg>
  name=$1 pkg=$2 fallback=$3 resolver=$4 arg=$5
  result=$("$resolver" "$arg") || result=""
  if [ -z "$result" ]; then
    result=$fallback
    echo "WARN: could not resolve latest ${pkg} - falling back to ${fallback}" >&2
  else
    echo "==> resolved ${pkg} -> ${result}"
  fi
  eval "$name=\$result"
}

if [ -z "$OPENCODE_VERSION" ]; then
  resolve_field OPENCODE_VERSION @opencode/cli 2.2.5 latest_npm @opencode/cli
else
  echo "==> OPENCODE_VERSION=$OPENCODE_VERSION (env pin)"
fi

if [ -z "$OPENCODE_PLATFORM_VERSION" ]; then
  resolve_field OPENCODE_PLATFORM_VERSION "@opencode/cli-linux-${OPENCODE_ARCH}" 2.2.5 \
    latest_npm "@opencode/cli-linux-${OPENCODE_ARCH}"
else
  echo "==> OPENCODE_PLATFORM_VERSION=$OPENCODE_PLATFORM_VERSION (env pin)"
fi

if [ -z "$CONTEXT7_VERSION" ]; then
  resolve_field CONTEXT7_VERSION @upstash/context7-mcp 4.4.4 latest_npm @upstash/context7-mcp
else
  echo "==> CONTEXT7_VERSION=$CONTEXT7_VERSION (env pin)"
fi

# The lean-ctx installer already pulls the latest release; this number only
# labels the fetched install.sh tag (or the default branch when it cannot be
# resolved, see fetch_lean_ctx).
if [ -z "$LEAN_CTX_VERSION" ]; then
  resolve_field LEAN_CTX_VERSION yvgude/lean-ctx 3.12.0 latest_github yvgude/lean-ctx
else
  echo "==> LEAN_CTX_VERSION=$LEAN_CTX_VERSION (env pin)"
fi

if [ -z "$MCP_VERSION" ]; then
  resolve_field MCP_VERSION mcp 2.3.0 latest_pypi mcp
else
  echo "==> MCP_VERSION=$MCP_VERSION (env pin)"
fi

if [ -z "$MCP_SERVER_FETCH_VERSION" ]; then
  resolve_field MCP_SERVER_FETCH_VERSION mcp-server-fetch 2026.10.28 latest_pypi mcp-server-fetch
else
  echo "==> MCP_SERVER_FETCH_VERSION=$MCP_SERVER_FETCH_VERSION (env pin)"
fi

if [ -z "$COCOINDEX_CODE_VERSION" ]; then
  resolve_field COCOINDEX_CODE_VERSION cocoindex-code 0.2.43 latest_pypi cocoindex-code
else
  echo "==> COCOINDEX_CODE_VERSION=$COCOINDEX_CODE_VERSION (env pin)"
fi

if [ -z "$ZOD_VERSION" ]; then
  resolve_field ZOD_VERSION zod 4.1.8 latest_npm zod
else
  echo "==> ZOD_VERSION=$ZOD_VERSION (env pin)"
fi

if [ -z "$FIRECRAWL_CLI_VERSION" ]; then
  resolve_field FIRECRAWL_CLI_VERSION firecrawl-cli 1.26.24 latest_npm firecrawl-cli
else
  echo "==> FIRECRAWL_CLI_VERSION=$FIRECRAWL_CLI_VERSION (env pin)"
fi

ADDED=0
SKIPPED=0

mark_added() {
  ADDED=$((ADDED + 1))
  echo "  added:   $1"
}

mark_skipped() {
  SKIPPED=$((SKIPPED + 1))
  echo "  skipped: $1"
}

# Generic skip-if-exists guard for one store artifact.
#
#   fetch_if_missing MARKER CMD [ARG...]
#
# MARKER is a file (e.g. a downloaded zip) or a directory (e.g. a git clone);
# it counts as present when it exists as a file or holds at least one entry
# as a directory. Present -> return 1 so the caller can report a skip;
# absent -> run CMD with the remaining arguments. Multi-step fetches pass a
# shell function as CMD (POSIX sh has no arrays, so commands are dispatched
# through "$@"). A failed fetch stays fatal: set -e is suspended in an
# if-condition, so a nonzero CMD status is turned into an explicit exit.
fetch_if_missing() {
  marker=$1
  shift
  if [ -e "$marker" ] && { [ -f "$marker" ] || [ -n "$(ls -A "$marker" 2>/dev/null)" ]; }; then
    return 1
  fi
  "$@" || exit $?
}

# --------------------------------------------------------------------------
# npm - one tarball per package.
# --------------------------------------------------------------------------

# True when a tarball for the package (any version) is already in the store.
# npm pack writes scoped packages as '@scope+name-<version>.tgz'.
# $glob is expanded unquoted on purpose (paths in this workspace have no spaces).
npm_tarball_present() {
  pkg=${1%@*}
  case "$pkg" in
    @*/*) glob="$STORE_DIR/npm/${pkg%%/*}+${pkg#*/}-"*.tgz ;;
    *)    glob="$STORE_DIR/npm/$pkg-"*.tgz ;;
  esac
  for f in $glob; do
    if [ -e "$f" ]; then
      return 0
    fi
  done
  return 1
}

npm_maybe_pack() {
  if npm_tarball_present "$1"; then
    mark_skipped "$1 (tarball already in store)"
  else
    npm pack "$1" --pack-destination "$STORE_DIR/npm"
    mark_added "$1"
  fi
}

echo "==> npm tarballs"
npm_maybe_pack "@opencode/cli@${OPENCODE_VERSION}"
npm_maybe_pack "@opencode/cli-linux-${OPENCODE_ARCH}@${OPENCODE_PLATFORM_VERSION}"
npm_maybe_pack "@upstash/context7-mcp@${CONTEXT7_VERSION}"
npm_maybe_pack "zod@${ZOD_VERSION}"
npm_maybe_pack "firecrawl-cli@${FIRECRAWL_CLI_VERSION}"

# NOTE: V1-API custom plugin tarballs (opencode-ai/plugin, model-fallback,
# dcp, websearch-cited) are no longer packed - the plugins are removed from
# the image until they are ported to the @opencode/plugin V2 API.

# --------------------------------------------------------------------------
# pip - full wheel closure.
# --------------------------------------------------------------------------

# True when at least one wheel is already in the store.
pip_wheels_present() {
  for f in "$STORE_DIR"/pip/*.whl; do
    if [ -e "$f" ]; then
      return 0
    fi
  done
  return 1
}

# The container ships pipx but NOT python3-pip; prefer the fetch venv's pip
# and fall back to python3 -m pip (e.g. on a dev host).
fetch_pip_wheels() {
  if [ -x /opt/pipx/venvs/mcp-server-fetch/bin/pip ]; then
    /opt/pipx/venvs/mcp-server-fetch/bin/pip download --dest "$STORE_DIR/pip" \
      "mcp==${MCP_VERSION}" "mcp-server-fetch==${MCP_SERVER_FETCH_VERSION}"
  else
    python3 -m pip download --dest "$STORE_DIR/pip" \
      "mcp==${MCP_VERSION}" "mcp-server-fetch==${MCP_SERVER_FETCH_VERSION}"
  fi
}

echo "==> python wheels (full closure)"
if pip_wheels_present; then
  mark_skipped "pip wheels (already in store)"
else
  fetch_pip_wheels
  mark_added "pip wheels: mcp==${MCP_VERSION}, mcp-server-fetch==${MCP_SERVER_FETCH_VERSION}"
fi

# Each store artifact has its OWN guard, so a partially-filled store self-heals
# on re-run: a store holding only the cocoindex-code base wheel no longer blocks
# the cpu embedding deps fetch (and vice versa).

# True when the cocoindex-code base wheel is already in the store.
cocoindex_wheels_present() {
  for f in "$STORE_DIR"/pip/cocoindex_code-*.whl; do
    if [ -e "$f" ]; then
      return 0
    fi
  done
  return 1
}

# The cocoindex-code base wheel. Same pip preference as fetch_pip_wheels:
# fetch venv's pip first.
fetch_cocoindex_base_wheel() {
  if [ -x /opt/pipx/venvs/mcp-server-fetch/bin/pip ]; then
    /opt/pipx/venvs/mcp-server-fetch/bin/pip download --dest "$STORE_DIR/pip" \
      "cocoindex-code==${COCOINDEX_CODE_VERSION}"
  else
    python3 -m pip download --dest "$STORE_DIR/pip" \
      "cocoindex-code==${COCOINDEX_CODE_VERSION}"
  fi
}

# The local-embedding closure (torch, transformers, sentence-transformers).
# The embedding deps come from the CPU torch index
# (download.pytorch.org/whl/cpu), NOT plain PyPI: on Linux PyPI's torch is the
# CUDA build and drags in the whole nvidia-* wheel set (~2-3 GB). The CPU wheel
# carries a +cpu local version, which sorts higher than the plain PyPI version,
# so pip prefers it once the extra index is in play. Store grows by roughly
# 300-400 MB total on the first run (CPU torch ~200 MB + NLP deps), by design
# (keyless offline embeddings).
# True when at least one torch wheel is already in the store.
cpu_embedding_wheels_present() {
  for f in "$STORE_DIR"/pip/torch-*.whl; do
    if [ -e "$f" ]; then
      return 0
    fi
  done
  return 1
}

# Same pip preference as fetch_pip_wheels: fetch venv's pip first.
fetch_cpu_embedding_wheels() {
  if [ -x /opt/pipx/venvs/mcp-server-fetch/bin/pip ]; then
    /opt/pipx/venvs/mcp-server-fetch/bin/pip download --dest "$STORE_DIR/pip" \
      --extra-index-url https://download.pytorch.org/whl/cpu \
      torch transformers sentence-transformers
  else
    python3 -m pip download --dest "$STORE_DIR/pip" \
      --extra-index-url https://download.pytorch.org/whl/cpu \
      torch transformers sentence-transformers
  fi
}

echo "==> python wheels (cocoindex-code base)"
if cocoindex_wheels_present; then
  mark_skipped "cocoindex-code base wheel (already in store)"
else
  fetch_cocoindex_base_wheel
  mark_added "cocoindex-code base wheel: cocoindex-code==${COCOINDEX_CODE_VERSION}"
fi

echo "==> python wheels (cpu embedding deps: torch/transformers/sentence-transformers)"
if cpu_embedding_wheels_present; then
  mark_skipped "cpu embedding deps (already in store)"
else
  fetch_cpu_embedding_wheels
  mark_added "cpu embedding deps: torch+transformers+sentence-transformers (from download.pytorch.org/whl/cpu)"
fi

# --------------------------------------------------------------------------
# bin - release binaries.
# --------------------------------------------------------------------------

# Fetch the lean-ctx release binary via its install script. The return status
# reflects reality: being called inside an if-condition suspends set -e, so
# every step returns 1 explicitly and the final test proves the binary landed.
# A resolved LEAN_CTX_VERSION pins install.sh to that release tag; the 3.12.0
# fallback pin is kept for tag honesty but an unresolved version also works:
# fetch install.sh from the default branch, which is the latest logic.
fetch_lean_ctx() {
  HOME=$(mktemp -d)
  if [ "$LEAN_CTX_VERSION" = "3.12.0" ]; then
    installer_url="https://raw.githubusercontent.com/yvgude/lean-ctx/main/install.sh"
  else
    installer_url="https://raw.githubusercontent.com/yvgude/lean-ctx/v${LEAN_CTX_VERSION}/install.sh"
  fi
  curl -fsSL "$installer_url" -o "$HOME/inst.sh" || return 1
  LEAN_CTX_NO_ONBOARD=1 sh "$HOME/inst.sh" --download || return 1
  cp "$HOME/.local/bin/lean-ctx" "$STORE_DIR/bin/lean-ctx" || return 1
  chmod 0755 "$STORE_DIR/bin/lean-ctx" || return 1
  rm -rf "$HOME"
  test -x "$STORE_DIR/bin/lean-ctx"
}

echo "==> lean-ctx binary"
if [ -e "$STORE_DIR/bin/lean-ctx" ]; then
  mark_skipped "lean-ctx ${LEAN_CTX_VERSION} (binary already in store)"
elif fetch_lean_ctx; then
  mark_added "lean-ctx ${LEAN_CTX_VERSION}"
else
  echo "WARN: lean-ctx binary fetch FAILED - store incomplete; builds fall back to network" >&2
fi

# --------------------------------------------------------------------------
# apt - .deb closure (root only).
# --------------------------------------------------------------------------

# True when at least one .deb is already in the store.
apt_debs_present() {
  for f in "$STORE_DIR"/apt/*.deb; do
    if [ -e "$f" ]; then
      return 0
    fi
  done
  return 1
}

fetch_apt_debs() {
  mkdir -p "$STORE_DIR/apt/partial"
  apt-get update
  apt-get install --reinstall --download-only -y --no-install-recommends \
    -o Dir::Cache::archives="$STORE_DIR/apt" \
    git curl jq ripgrep ca-certificates python3 pipx python3-venv coreutils procps
}

echo "==> apt debs (root only)"
if [ "$(id -u)" -eq 0 ]; then
  if apt_debs_present; then
    mark_skipped "apt debs (already in store)"
  else
    fetch_apt_debs
    mark_added "apt debs"
  fi
else
  echo "  apt section skipped - re-run with: docker compose exec -u root opencode sh populate-preinstall.sh"
fi

# --------------------------------------------------------------------------
# git/ - shallow clones of git-sourced artifacts (reserved for future use).
#
# Pattern: the marker is the clone directory; the clone is skipped while it
# holds at least one entry (an empty or partial clone refetches):
#
#   fetch_if_missing "$STORE_DIR/git/<name>" \
#     git clone --depth 1 <url> "$STORE_DIR/git/<name>"
#
# Working example (uncomment and fill in when a git-sourced artifact is
# needed; wrap with if/else + mark_added/mark_skipped to keep counts):
#
#   echo "==> git clones"
#   # fetch_if_missing "$STORE_DIR/git/example-repo" \
#   #   git clone --depth 1 https://github.com/example/example-repo.git \
#   #   "$STORE_DIR/git/example-repo"
# --------------------------------------------------------------------------

# --------------------------------------------------------------------------
# dist/ - zips, tarballs, and other direct-URL downloads (reserved for
# future use).
#
# Pattern: the marker is the downloaded file itself; the download is skipped
# while the file exists:
#
#   fetch_if_missing "$STORE_DIR/dist/<name>.zip" \
#     curl -fsSL <url> -o "$STORE_DIR/dist/<name>.zip"
#
# Working example (uncomment and fill in when a direct-download artifact is
# needed):
#
#   echo "==> direct downloads"
#   # fetch_if_missing "$STORE_DIR/dist/example-1.0.0.zip" \
#   #   curl -fsSL https://example.com/example-1.0.0.zip \
#   #   -o "$STORE_DIR/dist/example-1.0.0.zip"
# --------------------------------------------------------------------------

# --------------------------------------------------------------------------
# version manifest - the store is the lockfile; this records what it holds.
# Values read back from the store are what the Dockerfile globs consume, so
# this file is the audit trail (and the pin list for a reproducible re-run).
# --------------------------------------------------------------------------
{
  printf '%s\n' "# resolved by populate-preinstall.sh (latest-at-populate-time; env overrides recorded as pins)"
  printf '%s\n' "opencode=$OPENCODE_VERSION"
  printf '%s\n' "opencode-platform=$OPENCODE_PLATFORM_VERSION"
  printf '%s\n' "context7=$CONTEXT7_VERSION"
  printf '%s\n' "lean-ctx=$LEAN_CTX_VERSION"
  printf '%s\n' "mcp=$MCP_VERSION"
  printf '%s\n' "mcp-server-fetch=$MCP_SERVER_FETCH_VERSION"
  printf '%s\n' "cocoindex-code=$COCOINDEX_CODE_VERSION"
  printf '%s\n' "zod=$ZOD_VERSION"
  printf '%s\n' "firecrawl-cli=$FIRECRAWL_CLI_VERSION"
} > "$STORE_DIR/versions.lock"

echo ""
echo "==> done: ${ADDED} added, ${SKIPPED} skipped - store at ${STORE_DIR}"
echo "    sections: npm pip bin apt git dist"
echo "==> versions locked to pre-install/versions.lock"