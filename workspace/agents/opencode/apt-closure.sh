#!/bin/sh
# apt-closure.sh - offline-store helpers for the apt tier of
# populate-preinstall.sh. SOURCED, not executed: every name below is a
# function over its arguments and the sourcing script's globals (STORE_DIR,
# SCRIPT_DIR; APT_MANIFEST overridable), so test-apt-offline.sh exercises
# them with mock apt-cache/apt-get/dpkg binaries on PATH - no network, no
# root, no docker.
#
# Single source of truth for the image's apt package set is
# pre-install/packages-apt.txt (git-tracked): the Dockerfile's network
# fallback installs exactly those names (apt-install.sh), and this file
# resolves their FULL transitive .deb closure into <store>/apt/ so the
# offline build installs with dpkg alone - no apt resolver, no apt-get
# update, no network, no upgrade.
#
# Resolution is deliberately independent of THIS container's apt state: the
# populate container installs extra packages on top of the base image
# (curl, git, python3, openssl, ...) that a fresh build image does not
# have, so a plain `apt-get install --download-only` against live state
# would silently drop exactly those debs. Instead the closure is WALKED
# with `apt-cache depends --recurse` (state-independent) and every closure
# member is force-downloaded via `apt-get install --reinstall
# --download-only`.
#
# Assumed target (documented, pinned in versions.lock as apt-release and
# apt-arch): the node:22-bookworm-slim base image (Debian 12 bookworm) at
# the populating host's dpkg architecture. A store built for another
# release/architecture is caught at build time by the arch guard in
# apt-install.sh (loud network fallback).
#
# TOFU window (same caveat as every other store tier): the FIRST fetch of
# a .deb cannot be digest-verified - pins are recorded afterwards by a
# maintainer `--update-digests` run on a trusted connection.

# Manifest path. Overridable for tests (APT_MANIFEST env wins).
APT_MANIFEST="${APT_MANIFEST:-$SCRIPT_DIR/pre-install/packages-apt.txt}"

# Manifest packages: one per line, comments and blank lines stripped.
# Returns 1 (caller decides fatal) on a missing or package-less manifest:
# a comment-only list would otherwise silently produce an empty store tier
# that the build then resolves over the network - the exact silent drift
# this module exists to prevent.
apt_manifest_pkgs() {
  if [ ! -f "$APT_MANIFEST" ]; then
    echo "FATAL: apt manifest missing: $APT_MANIFEST (git-tracked source of the apt tier; restore it)" >&2
    return 1
  fi
  _pkgs=$(grep -vE '^[[:space:]]*(#|$)' "$APT_MANIFEST" 2>/dev/null) || _pkgs=
  if [ -z "$_pkgs" ]; then
    echo "FATAL: apt manifest holds no packages (comments only): $APT_MANIFEST" >&2
    return 1
  fi
  printf '%s\n' "$_pkgs"
}

# Full transitive closure of the manifest. Sets:
#   APT_ALL    newline-separated REAL package names (virtual <names>
#              dropped; OR-alternatives collapsed to the first candidate
#              apt-cache can resolve, mirroring what `apt-get install`
#              would pick)
#   APT_EDGES  "dep:dependent" lines from Depends AND PreDepends - the
#              install order must satisfy pre-depends at dpkg UNPACK time,
#              not just configure time
# Returns 1 when apt-cache itself fails (e.g. no apt lists yet).
#
# apt-cache depends --recurse output (one block per visited package):
#   git
#     Depends: libc6
#     PreDepends: libgcc-s1
#     Depends: <awk>
#     gawk                      <- provider continuation under a virtual
#     Depends: debconf | debconf-2.0
# Virtuals are satisfied by the base image's already-installed providers
# (e.g. debconf-2.0 <- debconf) and are deliberately NOT fetched; provider
# continuations are not walked either. The store therefore carries exactly
# what a fresh `apt-get install` would resolve - no more, no less.
apt_resolve_closure() {
  APT_ALL=
  APT_EDGES=
  _roots=$(apt_manifest_pkgs | tr '\n' ' ') || return 1
  _tmp=$(mktemp "${TMPDIR:-/tmp}/apt-closure.XXXXXX")
  if ! apt-cache depends --recurse --important \
        --no-recommends --no-suggests --no-conflicts --no-breaks \
        --no-replaces --no-enhances $_roots >"$_tmp" 2>/dev/null; then
    rm -f "$_tmp"
    echo "FATAL: apt-cache depends failed (apt lists present? populate runs apt-get update first)" >&2
    return 1
  fi
  _pkg=
  while IFS= read -r _line; do
    # strip leading whitespace with sed, then compare: a case pattern for
    # "leading tab" is a POSIX trap ([\ \t] matches a literal 't', swallowing
    # node lines that start with t)
    _trimmed=$(printf '%s' "$_line" | sed 's/^[[:space:]]*//')
    if [ "$_trimmed" != "$_line" ]; then _ind=1; else _ind=0; fi
    _line=$_trimmed
    [ -n "$_line" ] || continue
    if [ "$_ind" -eq 0 ]; then
      # node line: the visited package itself (may be <virtual>)
      _pkg=$_line
      case "$_line" in
        '<'*) : ;;
        *)
          case "
$APT_ALL
" in *"
$_line
"*) : ;; *) APT_ALL="$APT_ALL$_line
" ;; esac
          ;;
      esac
      continue
    fi
    case "$_line" in
      'Depends: '*)    _val=${_line#'Depends: '} ;;
      'PreDepends: '*) _val=${_line#'PreDepends: '} ;;
      *) continue ;;
    esac
    # drop the version constraint tail "libc6 (>= 2.34)" -> "libc6"
    _val=${_val%% (*}
    _picked=
    for _alt in $(printf '%s' "$_val" | tr '|' ' '); do
      _alt=$(printf '%s' "$_alt" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      [ -n "$_alt" ] || continue
      case "$_alt" in '<'*) continue ;; esac
      if [ -z "$_picked" ]; then
        if apt-cache policy "$_alt" 2>/dev/null | grep -q 'Candidate: [0-9]'; then
          _picked=$_alt
        elif [ "$(printf '%s' "$_val" | tr -cd '|' | wc -c)" -gt 0 ]; then
          echo "  apt closure: alternative '$_alt' has no candidate - trying next" >&2
        fi
      fi
    done
    if [ -n "$_picked" ]; then
      case "
$APT_ALL
" in *"
$_picked
"*) : ;; *) APT_ALL="$APT_ALL$_picked
" ;; esac
      if [ -n "$_pkg" ]; then
        _edge="${_picked}:${_pkg}"
        case "
$APT_EDGES
" in *"
$_edge
"*) : ;; *) APT_EDGES="$APT_EDGES$_edge
" ;; esac
      fi
    else
      echo "WARN: apt closure: no resolvable package for edge '$_val' of ${_pkg:-?} - assumed satisfied by the base image" >&2
    fi
  done <"$_tmp"
  rm -f "$_tmp"
  [ -n "$APT_ALL" ] || { echo "FATAL: apt closure walk produced no packages" >&2; return 1; }
}

# Dependencies-first ordering (Kahn) over the closure edges, restricted to
# the closure names. Prints one name per line. On a cycle (none expected in
# Debian's closure, guarded anyway) falls back to LC_ALL=C sort with a loud
# WARN: dpkg -i is a single transaction, so a mis-ordered Pre-Depends pair
# fails the build loudly and apt-install.sh repairs over the network -
# never silently.
apt_topo_order() { # $1 = names (newline list), $2 = edges ("dep:pkg" lines)
  _in() { # _in <newline-list> <item>
    case "
$1
" in *"
$2
"*) return 0 ;; *) return 1 ;; esac
  }
  _remaining=$1
  _edges=$2
  _out=
  while [ -n "$(printf '%s' "$_remaining" | tr -d '[:space:]')" ]; do
    _progress=0
    _next=
    for _n in $_remaining; do
      [ -n "$_n" ] || continue
      _ready=1
      for _e in $_edges; do
        [ "${_e#*:}" = "$_n" ] || continue
        if _in "$_remaining" "${_e%%:*}"; then _ready=0; break; fi
      done
      if [ "$_ready" -eq 1 ]; then
        _out="$_out$_n
"
        _progress=1
      else
        _next="$_next$_n
"
      fi
    done
    if [ "$_progress" -eq 0 ]; then
      echo "WARN: apt closure has a dependency cycle - install order falls back to alphabetical" >&2
      printf "%s" "$_out"
      printf '%s\n' "$_remaining" | LC_ALL=C sort
      return 0
    fi
    _remaining=$_next
  done
  printf '%s' "$_out"
}

# Write store/apt/install-order.txt: the deps-first order of the staged debs
# (base names, one per line, #-prefixed header), consumed by apt-install.sh
# as a single dpkg -i transaction. Every closure name must map to a staged
# deb - a name without one means resolution was incomplete and the offline
# install would fail at dpkg time; failing HERE is cheap, failing at build
# time is not. Deb names are <name>_<version>_<arch>.deb; apt stages exactly
# one candidate version per name into the fresh staging dir, so the sort
# below only disambiguates unexpected leftovers.
apt_write_install_order() { # $1 = staging dir with debs, $2 = output file
  _stage=$1
  _outf=$2
  _order=$(apt_topo_order "$APT_ALL" "$APT_EDGES")
  _body=
  _missing=0
  for _n in $_order; do
    [ -n "$_n" ] || continue
    _deb=$(ls "$_stage/${_n}_"*.deb 2>/dev/null | LC_ALL=C sort | tail -n 1)
    if [ -z "$_deb" ]; then
      echo "FATAL: no .deb staged for closure package $_n (resolution incomplete?)" >&2
      _missing=1
      continue
    fi
    _body="$_body${_deb##*/}
"
  done
  if [ "$_missing" -ne 0 ]; then
    echo "FATAL: apt closure incomplete - store apt tier NOT updated" >&2
    return 1
  fi
  {
    printf '%s\n' "# deps-first install order for store/apt/*.deb (single dpkg -i transaction)"
    printf '%s\n' "# written by populate-preinstall.sh from pre-install/packages-apt.txt;"
    printf '%s\n' "# consumed by apt-install.sh at build time. Regenerated on every apt fetch."
    printf '%s' "$_body"
  } >"$_outf"
}

# Skip-path guard: true when the store already covers the CURRENT manifest
# (install order present AND every manifest package has a deb). The apt
# analogue of same_version_in_store - a store built from an older manifest
# self-heals on the next populate run instead of staying stale forever.
apt_store_covers_manifest() {
  [ -f "$STORE_DIR/apt/install-order.txt" ] || return 1
  _pkgs=$(apt_manifest_pkgs) || return 1
  for _p in $_pkgs; do
    ls "$STORE_DIR/apt/${_p}_"*.deb >/dev/null 2>&1 || return 1
  done
  return 0
}

# Fetch the full closure into a staging dir, write the install order, then
# swap it in. store/apt/*.deb is REGENERATED per fetch - one closure, one
# consistent version set (two versions of a package in one dpkg -i
# transaction are a hard error) - while the pip/npm tiers keep their
# add-only dependency policy. Requires root and network (populate tier).
fetch_apt_debs() {
  _stage="$STORE_DIR/apt/.staging.$$"
  rm -rf "$_stage"
  mkdir -p "$_stage/partial"
  apt-get update
  _names=$(apt_topo_order "$APT_ALL" "$APT_EDGES" | tr "\n" " ")
  # --reinstall force-downloads EVERY closure member even when this
  # container already has it installed: the populate container's apt state
  # is richer than the fresh build image's and must not filter the closure.
  # shellcheck disable=SC2086
  apt-get install --reinstall --download-only -y --no-install-recommends \
    -o Dir::Cache::archives="$_stage" $_names
  apt_write_install_order "$_stage" "$STORE_DIR/apt/install-order.txt" || {
    rm -rf "$_stage"
    return 1
  }
  rm -f "$STORE_DIR"/apt/*.deb
  mv "$_stage"/*.deb "$STORE_DIR/apt/"
  rm -rf "$_stage"
}
