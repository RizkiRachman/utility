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
set -eu

# Versions - must match the Dockerfile ARG defaults (env-overridable).
OPENCODE_VERSION="${OPENCODE_VERSION:-2.2.5}"
OPENCODE_ARCH="${OPENCODE_ARCH:-arm64}"  # @opencode/cli-linux-${OPENCODE_ARCH}
OPENCODE_PLATFORM_VERSION="${OPENCODE_PLATFORM_VERSION:-2.2.5}"
CONTEXT7_VERSION="${CONTEXT7_VERSION:-4.4.4}"
LEAN_CTX_VERSION="${LEAN_CTX_VERSION:-3.12.0}"
MCP_VERSION="${MCP_VERSION:-2.3.0}"
MCP_SERVER_FETCH_VERSION="${MCP_SERVER_FETCH_VERSION:-2026.10.28}"
COCOINDEX_CODE_VERSION="${COCOINDEX_CODE_VERSION:-0.2.43}"  # must match Dockerfile ARG
# @firecrawl/opencode runtime dependency + CLI companion (offline store pins)
ZOD_VERSION="${ZOD_VERSION:-4.1.8}"
FIRECRAWL_CLI_VERSION="${FIRECRAWL_CLI_VERSION:-1.26.24}"

STORE_DIR=$(cd "$(dirname "$0")" && pwd)/pre-install
mkdir -p "$STORE_DIR/npm" "$STORE_DIR/pip" "$STORE_DIR/bin" "$STORE_DIR/apt" \
  "$STORE_DIR/git" "$STORE_DIR/dist"

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

# True when the cocoindex-code wheel is already in the store.
cocoindex_wheels_present() {
  for f in "$STORE_DIR"/pip/cocoindex_code-*.whl; do
    if [ -e "$f" ]; then
      return 0
    fi
  done
  return 1
}

# The base wheel plus the local-embedding closure (torch, transformers,
# sentence-transformers). The embedding deps come from the CPU torch index
# (download.pytorch.org/whl/cpu), NOT plain PyPI: on Linux PyPI's torch is the
# CUDA build and drags in the whole nvidia-* wheel set (~2-3 GB). The CPU wheel
# carries a +cpu local version, which sorts higher than the plain PyPI version,
# so pip prefers it once the extra index is in play. Store grows by roughly
# 300-400 MB total on the first run (CPU torch ~200 MB + NLP deps), by design
# (keyless offline embeddings).
# Same pip preference as fetch_pip_wheels: fetch venv's pip first.
fetch_cocoindex_wheels() {
  if [ -x /opt/pipx/venvs/mcp-server-fetch/bin/pip ]; then
    /opt/pipx/venvs/mcp-server-fetch/bin/pip download --dest "$STORE_DIR/pip" \
      "cocoindex-code==${COCOINDEX_CODE_VERSION}"
    /opt/pipx/venvs/mcp-server-fetch/bin/pip download --dest "$STORE_DIR/pip" \
      --extra-index-url https://download.pytorch.org/whl/cpu \
      torch transformers sentence-transformers
  else
    python3 -m pip download --dest "$STORE_DIR/pip" \
      "cocoindex-code==${COCOINDEX_CODE_VERSION}"
    python3 -m pip download --dest "$STORE_DIR/pip" \
      --extra-index-url https://download.pytorch.org/whl/cpu \
      torch transformers sentence-transformers
  fi
}

echo "==> python wheels (cocoindex-code base + cpu embedding deps)"
if cocoindex_wheels_present; then
  mark_skipped "cocoindex-code wheels (already in store)"
else
  fetch_cocoindex_wheels
  mark_added "cocoindex-code wheels: cocoindex-code==${COCOINDEX_CODE_VERSION} + cpu embedding deps (torch/transformers/sentence-transformers)"
fi

# --------------------------------------------------------------------------
# bin - release binaries.
# --------------------------------------------------------------------------

# Fetch the lean-ctx release binary via its install script.
fetch_lean_ctx() {
  HOME=$(mktemp -d)
  curl -fsSL \
    "https://raw.githubusercontent.com/yvgude/lean-ctx/v${LEAN_CTX_VERSION}/install.sh" \
    -o "$HOME/inst.sh"
  LEAN_CTX_NO_ONBOARD=1 sh "$HOME/inst.sh" --download
  cp "$HOME/.local/bin/lean-ctx" "$STORE_DIR/bin/lean-ctx"
  chmod 0755 "$STORE_DIR/bin/lean-ctx"
  rm -rf "$HOME"
}

echo "==> lean-ctx binary"
if fetch_if_missing "$STORE_DIR/bin/lean-ctx" fetch_lean_ctx; then
  mark_added "lean-ctx ${LEAN_CTX_VERSION}"
else
  mark_skipped "lean-ctx ${LEAN_CTX_VERSION} (binary already in store)"
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

echo ""
echo "==> done: ${ADDED} added, ${SKIPPED} skipped - store at ${STORE_DIR}"
echo "    sections: npm pip bin apt git dist"
