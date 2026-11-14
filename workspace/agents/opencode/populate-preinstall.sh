#!/bin/sh
# Populate the offline package store (workspace-root pre-installer/) used by
# the Docker build.
#
# The store lives at <workspace-root>/pre-installer/ (env PREINSTALL_STORE
# overrides) and is fully gitignored: its contents live only on the local
# disk / inside the workspace volume and are NEVER committed or pushed. The
# store is portable - copy the workspace to another machine and the store
# comes with it. Only the version lock (agents/opencode/pre-install/
# versions.lock) is git-tracked.
#
# Idempotent and VERSION-AWARE: an artifact is skipped only when the SAME
# version is already in the store; a different version is fetched and the old
# copies of that package are pruned (the Dockerfile tiers are single-match
# globs, so two versions on disk break them). Pruning runs on the SKIP path
# too, so a store that predates pruning self-heals instead of lingering
# forever. The opencode platform tarballs are additionally pruned by ARCH:
# mixed-platform stores (arm64 files on an x64 host) cause npm EBADPLATFORM at
# build time. Dependency closures are never pruned - add-only, see the
# version-aware guard header. The torch/transformers closure keeps
# skip-if-present (huge, slow); REFRESH_ML=1 forces a refresh.
# Root is required only for the apt section. Sections: npm pip bin apt git dist.
#
# Cert refresh: the detector runs on EVERY run before CA trust, so rotated
# corporate MITM roots are re-derived from the live wire. certs/ (workspace
# root, single source) keeps manual certs and replaces only
# zscaler-autodetected-*.crt; certs/sync-certs.sh mirrors the set into the
# submodule cert dirs after every run.
#
# Version policy: latest at populate time - the STORE is the lockfile. The
# Dockerfile store-first tiers are glob-based (...-*.tgz / *-*.whl), so the
# store always governs offline installs; only the network fallbacks care about
# numbers, and those are now "latest" when the Dockerfile ARG is empty.
# The exact versions used by this run are written to
# agents/opencode/pre-install/versions.lock (git-tracked).
# Env overrides (OPENCODE_VERSION=... sh populate-preinstall.sh) win and are
# the reproducibility escape hatch.
set -eu

# Versions - env-overridable. Empty here means "resolve latest below, after
# the CA-trust block" (resolution needs network + trusted corporate CAs).
OPENCODE_VERSION="${OPENCODE_VERSION:-}"
# @opencode/cli-linux-<arch> platform suffix. npm platform names are x64 /
# arm64; the preinstall container always runs on the host's NATIVE arch, so the
# running machine's uname -m is the correct default (a hardcoded arm64 default
# installed arm64 tarballs on x64 Docker hosts -> npm EBADPLATFORM at build).
OPENCODE_ARCH="${OPENCODE_ARCH:-}"
OPENCODE_PLATFORM_VERSION="${OPENCODE_PLATFORM_VERSION:-}"
CONTEXT7_VERSION="${CONTEXT7_VERSION:-}"
LEAN_CTX_VERSION="${LEAN_CTX_VERSION:-}"
MCP_VERSION="${MCP_VERSION:-}"
MCP_SERVER_FETCH_VERSION="${MCP_SERVER_FETCH_VERSION:-}"
COCOINDEX_CODE_VERSION="${COCOINDEX_CODE_VERSION:-}"
# @firecrawl/opencode runtime dependency + CLI companion (offline store pins)
ZOD_VERSION="${ZOD_VERSION:-}"
FIRECRAWL_CLI_VERSION="${FIRECRAWL_CLI_VERSION:-}"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
# Store: workspace-root pre-installer/ - the single source shared across all
# submodules. PREINSTALL_STORE overrides for non-standard checkouts.
STORE_DIR="${PREINSTALL_STORE:-$REPO_ROOT/pre-installer}"
# The version lock stays inside the agents/opencode submodule (git-tracked).
LOCK_FILE="$SCRIPT_DIR/pre-install/versions.lock"
mkdir -p "$(dirname "$LOCK_FILE")"
mkdir -p "$STORE_DIR/npm" "$STORE_DIR/pip" "$STORE_DIR/bin" "$STORE_DIR/apt" \
  "$STORE_DIR/git" "$STORE_DIR/dist"

# Trust extra root CAs from the workspace-root certs/ folder - the single
# cert source shared across submodules (corporate MITM proxies like Zscaler).
# Needs root; warn-only so non-root runs still proceed.
#
# Rotation-ready: refresh auto-detected MITM certs from the live wire on every
# run (corporate roots rotate). The detector lives in certs/ and seeds the
# parent folder; certs/sync-certs.sh then mirrors the set into the submodule
# cert dirs. Manual certs in certs/ are never touched.
# Best-effort: a failed probe must not abort the store population.
# The trust block below only installs what is in certs/ - it runs after the
# detector so a freshly refreshed set is what gets trusted.
echo "==> probing network for TLS interception (cert refresh)"
sh "$REPO_ROOT/certs/detect-zscaler.sh" "$REPO_ROOT/certs" || true
sh "$REPO_ROOT/certs/sync-certs.sh" || true

ca_trusted=0
for crt in "$REPO_ROOT/certs"/*.crt; do
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
# pip/python trust: aim pip, requests, and openssl at the SYSTEM CA bundle.
#
# pip validates TLS against its bundled certifi store by default - certifi
# does NOT contain the corporate MITM intermediates the block above installed
# into the system trust store, so pip downloads fail SSL on an inspected host
# even though curl/update-ca-certificates succeeded. The system bundle is
# rebuilt by update-ca-certificates from certs/*.crt and carries the zscaler
# chain; exporting it covers the torch/transformers CPU wheel downloads from
# download.pytorch.org (inspected by zscaler, unlike pypi.org). Inherited env
# values win (existing pins stay honored). These exports hold for everything
# below in this shell: the version resolvers and every pip call site.
# --------------------------------------------------------------------------
pip_ca_bundle=
for ca_bundle_candidate in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/cert.pem; do
  if [ -f "$ca_bundle_candidate" ]; then
    pip_ca_bundle=$ca_bundle_candidate
    break
  fi
done
if [ -n "$pip_ca_bundle" ]; then
  export PIP_CERT="${PIP_CERT:-$pip_ca_bundle}"
  export REQUESTS_CA_BUNDLE="${REQUESTS_CA_BUNDLE:-$pip_ca_bundle}"
  export SSL_CERT_FILE="${SSL_CERT_FILE:-$pip_ca_bundle}"
  echo "==> pip/python TLS trust via system bundle: PIP_CERT/REQUESTS_CA_BUNDLE/SSL_CERT_FILE=$pip_ca_bundle"
else
  echo "WARN: no system CA bundle found (looked for /etc/ssl/certs/ca-certificates.crt, /etc/pki/tls/cert.pem) - pip keeps its certifi defaults" >&2
fi

# --------------------------------------------------------------------------
# opencode platform arch - follows the machine running this script.
#
# The preinstall container is started on the host's native architecture, so
# uname -m here is the platform the image will run on (no emulation in the
# normal build path). Resolved BEFORE the version block below because
# OPENCODE_PLATFORM_VERSION resolves against @opencode/cli-linux-<arch>.
# OPENCODE_ARCH in the environment wins (pins cross-builds, e.g. building an
# arm64 image from an x64 host).
# --------------------------------------------------------------------------
if [ -z "$OPENCODE_ARCH" ]; then
  case "$(uname -m)" in
    x86_64)  OPENCODE_ARCH=x64 ;;
    aarch64) OPENCODE_ARCH=arm64 ;;
    *) OPENCODE_ARCH=arm64; echo "WARN: unknown arch $(uname -m) - defaulting arm64" >&2 ;;
  esac
  echo "==> detected opencode arch: $OPENCODE_ARCH"
else
  echo "==> OPENCODE_ARCH=$OPENCODE_ARCH (env pin)"
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
# version-aware store guards
#
# Presence globs alone are wrong in both directions: an artifact already in the
# store never updates (cocoindex-code stuck on its first version forever), and
# after a bump the old file LINGERS next to the new one - which breaks the
# Dockerfile's store tiers, because they are single-match globs
# (`npm install -g /pi/npm/@opencode+cli-*.tgz` fails with two versions on
# disk). So: skip only when the SAME version is already stored, otherwise
# fetch and PRUNE the old copies of that exact package.
#
# PRUNE IS CONSERVATIVE BY DESIGN: only the primary artifact's own old files
# are removed. Dependency-closure wheels (mcp_*, torch, transformers, and
# friends) are ADD-ONLY - a closure resolved for a new parent may still need an
# older dependency wheel, and guessing which transitive wheels are dead is how
# offline installs break. Extra dep wheels are harmless (pip resolves by name
# and version); missing ones are not.
# --------------------------------------------------------------------------

# Version embedded in a store filename: strips everything up to the last dash
# before the extension ("opencode-cli-2.3.0.tgz" -> "2.3.0").
store_version_of() { # store_version_of <file-path>
  base=${1##*/}
  base=${base%.*}
  printf '%s' "${base##*-}"
}

# Version of a WHEEL filename. Wheel naming is
# <pkg>-<version>-<python>-<abi>-<platform>.whl, so the version is the SECOND
# dash field - NOT the last (dashes inside the version's abi/platform tail, and
# multi-dash package names like cocoindex_code, both defeat store_version_of):
#   cocoindex_code-0.2.43-py3-none-any.whl          -> 0.2.43
#   aiohttp-3.14.5-cp311-cp311-manylinux...whl      -> 3.14.5
wheel_version_of() { # wheel_version_of <file-path>
  base=${1##*/}
  base=${base%.whl}
  printf '%s' "$base" | cut -d- -f2
}

# 0 when some file matching GLOB (shell glob, may match nothing) holds
# WANTED-VERSION. The glob is passed QUOTED and word-split inside so a
# multi-match expansion cannot be mistaken for glob+version arguments.
#
#   same_version_in_store '<glob>' <wanted-version>
#
# Paths in this workspace have no spaces, so unquoted splitting is deliberate.
same_version_in_store() {
  _glob=$1
  _want=$2
  for _f in $_glob; do
    [ -e "$_f" ] || continue
    if [ "$(store_version_of "$_f")" = "$_want" ]; then
      return 0
    fi
  done
  return 1
}

# 0 when some wheel matching GLOB already holds WANTED-VERSION (wheel naming).
same_wheel_version_in_store() {
  _glob=$1
  _want=$2
  for _f in $_glob; do
    [ -e "$_f" ] || continue
    if [ "$(wheel_version_of "$_f")" = "$_want" ]; then
      return 0
    fi
  done
  return 1
}

# Delete every match of GLOB whose version differs from KEEP-VERSION.
#
#   prune_old_versions '<glob>' <keep-version>
#
# Prints each removed path. Sibling packages that share a filename prefix
# (opencode-cli-* vs opencode-cli-linux-*) are never in the same glob: each
# caller passes the tightest pattern for its own artifact.
prune_old_versions() {
  _glob=$1
  _keep=$2
  for _f in $_glob; do
    [ -e "$_f" ] || continue
    if [ "$(store_version_of "$_f")" != "$_keep" ]; then
      if rm -f "$_f"; then
        echo "  pruned:  $_f (kept $_keep)"
      else
        echo "WARN: could not prune $_f" >&2
      fi
    fi
  done
}

# Wheel flavour of prune_old_versions (see wheel_version_of for the naming).
prune_old_wheel_versions() {
  _glob=$1
  _keep=$2
  for _f in $_glob; do
    [ -e "$_f" ] || continue
    if [ "$(wheel_version_of "$_f")" != "$_keep" ]; then
      if rm -f "$_f"; then
        echo "  pruned:  $_f (kept $_keep)"
      else
        echo "WARN: could not prune $_f" >&2
      fi
    fi
  done
}

# --------------------------------------------------------------------------
# opencode platform arch in a store filename.
#
# Store names are flat (npm pack drops the scope and the slashes):
#   @opencode/cli-linux-arm64@2.3.0 -> opencode-cli-linux-arm64-2.3.0.tgz
# so the arch is everything between the "linux-" marker and the LAST dash
# before "<version>.tgz". Parsed by sed rather than store_version_of, which only
# understands the trailing version field. Anchoring on the trailing
# -<version>.tgz pair (dots allowed in the version, no dash) is what keeps a
# non-matching name from yielding a wrong arch.
# --------------------------------------------------------------------------
store_arch_of() { # store_arch_of <opencode-platform-tarball>
  printf '%s' "${1##*/}" | sed -n 's/^opencode-cli-linux-\(.*\)-[0-9][^-]*\.tgz$/\1/p'
}

# Delete opencode tarballs in the store that the Dockerfile must never see.
#
# Cross-arch cleanup: the store is portable and predates the arch fix, so it
# can hold OTHER-platform tarballs (e.g. arm64 files fetched on an x64 host
# before OPENCODE_ARCH followed uname -m) next to the wanted ones. Those are
# useless for this image and were the arm64-on-x64 EBADPLATFORM source.
#
#   prune_opencode_tarballs <arch> <cli-version> <platform-version>
#
# Plain CLI tarballs (opencode-cli-<v>.tgz) are arch-neutral: keep only the
# wanted version. Platform tarballs (opencode-cli-linux-<arch>-<v>.tgz) keep
# only <arch> at the wanted platform version. Sibling packages with another
# prefix (firecrawl-cli-*, zod-*) never match these globs.
prune_opencode_tarballs() {
  _arch=$1
  _cli_keep=$2
  _plat_keep=$3
  prune_old_versions "$STORE_DIR/npm/opencode-cli-[0-9]*.tgz" "$_cli_keep"
  for _f in "$STORE_DIR"/npm/opencode-cli-linux-*.tgz; do
    [ -e "$_f" ] || continue
    if [ "$(store_arch_of "$_f")" != "$_arch" ] || \
       [ "$(store_version_of "$_f")" != "$_plat_keep" ]; then
      if rm -f "$_f"; then
        echo "  pruned:  $_f (kept ${_arch}/${_plat_keep})"
      else
        echo "WARN: could not prune $_f" >&2
      fi
    fi
  done
}

# --------------------------------------------------------------------------
# npm - one tarball per package.
# --------------------------------------------------------------------------

# Store glob for an npm package spec (version stripped). This npm writes scoped
# packages WITHOUT the @scope/ or + separator:
#   @upstash/context7-mcp@4.7.0 -> upstash-context7-mcp-4.7.0.tgz
#   @opencode/cli-linux-arm64    -> opencode-cli-linux-arm64-<v>.tgz
# (verified with `npm pack @upstash/context7-mcp@4.7.0`). The result is a
# PATTERN, not a file list - callers pass it quoted to the guard helpers, which
# split it.
npm_store_glob() {
  pkg=${1%@*}
  case "$pkg" in
    @*/*)
      # @scope/name -> scope-name-*.tgz (drop the @, turn the / into -)
      _scope=${pkg%%/*}
      _name=${pkg#*/}
      printf '%s' "$STORE_DIR/npm/${_scope#@}-${_name}-*.tgz" ;;
    *)    printf '%s' "$STORE_DIR/npm/$pkg-*.tgz" ;;
  esac
}

# Pack PKG@VERSION unless that exact version is already in the store. Pruning
# runs on BOTH paths: a store populated before pruning existed still holds the
# previous version next to the wanted one (that is how opencode-cli 2.2.5 +
# 2.3.0 ended up side by side and broke the single-match Dockerfile glob), and
# a skip is exactly when that legacy state is sitting there unfixed. After the
# prune the package's older tarballs are gone, so the Dockerfile's single-match
# glob (@opencode+cli-*.tgz) can never see two versions. Deps inside the
# tarballs stay untouched - npm install -g resolves them at install time from
# its own store tier, not from sibling files here.
npm_maybe_pack() {
  spec=$1
  ver=${spec##*@}
  glob=$(npm_store_glob "$spec")
  if same_version_in_store "$glob" "$ver"; then
    prune_old_versions "$glob" "$ver"
    mark_skipped "$spec (same version in store)"
    return 0
  fi
  npm pack "$spec" --pack-destination "$STORE_DIR/npm"
  prune_old_versions "$glob" "$ver"
  mark_added "$spec"
}

echo "==> npm tarballs"
npm_maybe_pack "@opencode/cli@${OPENCODE_VERSION}"
npm_maybe_pack "@opencode/cli-linux-${OPENCODE_ARCH}@${OPENCODE_PLATFORM_VERSION}"
# Cross-arch / mixed-version cleanup for BOTH opencode artifacts: the stores
# above only know their own glob, so stale arm64 platform tarballs on an x64
# host (or a legacy extra version) survive a skip. Runs once, after both, so
# the store is single-arch and single-version whatever path it took.
prune_opencode_tarballs "$OPENCODE_ARCH" "$OPENCODE_VERSION" "$OPENCODE_PLATFORM_VERSION"
npm_maybe_pack "@upstash/context7-mcp@${CONTEXT7_VERSION}"
npm_maybe_pack "zod@${ZOD_VERSION}"
npm_maybe_pack "firecrawl-cli@${FIRECRAWL_CLI_VERSION}"

# NOTE: V1-API custom plugin tarballs (opencode-ai/plugin, model-fallback,
# dcp, websearch-cited) are no longer packed - the plugins are removed from
# the image until they are ported to the @opencode/plugin V2 API.

# --------------------------------------------------------------------------
# pip - full wheel closure.
# --------------------------------------------------------------------------

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

# Guarded by the PRIMARY artifact (the mcp_server_fetch wheel): the closure is
# one `pip download`, so a new mcp-server-fetch version must refetch the whole
# closure - its deps may have moved with it. Pruning is primary-only: the dep
# wheels stay add-only (see the version-aware guard header), which keeps the
# Dockerfile's mcp_server_fetch-*.whl single-match glob safe while leaving
# pip's resolver every dependency version it might need.
echo "==> python wheels (full closure)"
if same_wheel_version_in_store "$STORE_DIR/pip/mcp_server_fetch-*.whl" \
    "$MCP_SERVER_FETCH_VERSION"; then
  # Prune on the skip path too: a store populated before pruning existed can
  # hold the previous primary wheel next to the wanted one and break the
  # Dockerfile's single-match *.whl glob without this.
  prune_old_wheel_versions "$STORE_DIR/pip/mcp_server_fetch-*.whl" \
    "$MCP_SERVER_FETCH_VERSION"
  mark_skipped "pip wheels: mcp-server-fetch==${MCP_SERVER_FETCH_VERSION} (same version in store)"
else
  fetch_pip_wheels
  prune_old_wheel_versions "$STORE_DIR/pip/mcp_server_fetch-*.whl" \
    "$MCP_SERVER_FETCH_VERSION"
  mark_added "pip wheels: mcp==${MCP_VERSION}, mcp-server-fetch==${MCP_SERVER_FETCH_VERSION}"
fi

# Each store artifact has its OWN guard, so a partially-filled store self-heals
# on re-run: a store holding only the cocoindex-code base wheel no longer blocks
# the cpu embedding deps fetch (and vice versa).

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
#
# This closure KEEPS skip-if-present (unlike the version-aware artifacts
# above): it is hundreds of MB and torch's patch releases would re-download it
# on every populate run. Refresh it deliberately:
#   - delete pre-install/pip/torch-*.whl, or
#   - REFRESH_ML=1 sh populate-preinstall.sh
# REFRESH_ML=1 also prunes the previous torch/transformers/sentence-transformers
# wheels after the fetch. Those three are the only pruned names - their
# transitive closure (nvidia-*, huggingface_hub, tokenizers, ...) stays add-only
# like every other dependency wheel.
REFRESH_ML="${REFRESH_ML:-0}"

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
if same_wheel_version_in_store "$STORE_DIR/pip/cocoindex_code-*.whl" \
    "$COCOINDEX_CODE_VERSION"; then
  # Prune on the skip path too (see the mcp_server_fetch block above): the
  # Dockerfile consumes a single-match cocoindex_code-*.whl glob.
  prune_old_wheel_versions "$STORE_DIR/pip/cocoindex_code-*.whl" \
    "$COCOINDEX_CODE_VERSION"
  mark_skipped "cocoindex-code==${COCOINDEX_CODE_VERSION} (same version in store)"
else
  fetch_cocoindex_base_wheel
  prune_old_wheel_versions "$STORE_DIR/pip/cocoindex_code-*.whl" \
    "$COCOINDEX_CODE_VERSION"
  mark_added "cocoindex-code base wheel: cocoindex-code==${COCOINDEX_CODE_VERSION}"
fi

# Prune one ML name to its newest stored wheel. Called only after a fetch, but
# the glob is still checked: with `set -u` a bare `ls` on no match would abort.
prune_ml_wheels() { # prune_ml_wheels <name>   e.g. torch
  _newest=
  for _f in "$STORE_DIR/pip/$1-"*.whl; do
    [ -e "$_f" ] || continue
    _newest=$_f
  done
  if [ -n "$_newest" ]; then
    prune_old_wheel_versions "$STORE_DIR/pip/$1-*.whl" "$(wheel_version_of "$_newest")"
  fi
}

echo "==> python wheels (cpu embedding deps: torch/transformers/sentence-transformers)"
if [ "$REFRESH_ML" = "1" ]; then
  echo "  REFRESH_ML=1 - refetching the ML closure"
  fetch_cpu_embedding_wheels
  prune_ml_wheels torch
  prune_ml_wheels transformers
  prune_ml_wheels sentence_transformers
  mark_added "cpu embedding deps: torch+transformers+sentence-transformers (REFRESH_ML=1)"
elif cpu_embedding_wheels_present; then
  mark_skipped "cpu embedding deps (already in store - REFRESH_ML=1 to refresh)"
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
# The platform arch is part of what the store holds: without it a re-run on a
# different machine silently mixes arm64 and x64 tarballs.
# --------------------------------------------------------------------------
{
  printf '%s\n' "# resolved by populate-preinstall.sh (latest-at-populate-time; env overrides recorded as pins)"
  printf '%s\n' "opencode=$OPENCODE_VERSION"
  printf '%s\n' "opencode-arch=$OPENCODE_ARCH"
  printf '%s\n' "opencode-platform=$OPENCODE_PLATFORM_VERSION"
  printf '%s\n' "context7=$CONTEXT7_VERSION"
  printf '%s\n' "lean-ctx=$LEAN_CTX_VERSION"
  printf '%s\n' "mcp=$MCP_VERSION"
  printf '%s\n' "mcp-server-fetch=$MCP_SERVER_FETCH_VERSION"
  printf '%s\n' "cocoindex-code=$COCOINDEX_CODE_VERSION"
  printf '%s\n' "zod=$ZOD_VERSION"
  printf '%s\n' "firecrawl-cli=$FIRECRAWL_CLI_VERSION"
} > "$LOCK_FILE"

echo ""
echo "==> done: ${ADDED} added, ${SKIPPED} skipped - store at ${STORE_DIR}"
echo "    sections: npm pip bin apt git dist"
echo "==> versions locked to $LOCK_FILE"