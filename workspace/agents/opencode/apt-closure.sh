#!/bin/sh
# apt-closure.sh - offline-store helpers for the apt tier of
# populate-preinstall.sh. SOURCED, not executed: every name below is a
# function over its arguments and the sourcing script's globals (STORE_DIR,
# SCRIPT_DIR; APT_MANIFEST overridable), so test-apt-offline.sh exercises
# them with mock apt-get/dpkg binaries on PATH - no network, no
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
# would silently drop exactly those debs. Instead the closure is PLANNED
# by apt's own solver against an EMPTY dpkg status file (apt sees nothing
# installed and pulls the full dependency tree of the manifest), and the
# whole plan is downloaded with --download-only into the store.
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
  # Windows checkouts can carry CRLF (autocrlf) - 'git\r' matches no apt
  # index and poisons the closure and store-tier matching. Strip CR at read.
  _pkgs=$(tr -d '\r' < "$APT_MANIFEST" | grep -vE '^[[:space:]]*(#|$)' 2>/dev/null) || _pkgs=
  if [ -z "$_pkgs" ]; then
    echo "FATAL: apt manifest holds no packages (comments only): $APT_MANIFEST" >&2
    return 1
  fi
  printf '%s\n' "$_pkgs"
}

# Full transitive closure of the manifest, planned by apt's OWN solver.
# Sets:
#   APT_ALL       newline-separated package names, deduped
#   APT_ORDER     the same names in apt's plan order (dependencies first)
#   APT_SCHEDULE  the plan as replayable ops: "u <pkg>" (unpack) and
#                 "c <pkg>" (configure) in apt's own interleaved order -
#                 Pre-Depends must see the prerequisite CONFIGURED when the
#                 dependent is unpacked, so the Conf checkpoints are part of
#                 the order (an unpack-only order made dpkg refuse
#                 python3-minimal and cascaded 12 broken packages)
# Returns 1 when the simulation fails (e.g. apt lists missing).
#
# Why not a hand walk over `apt-cache depends --recurse`: real apt
# (2.6/bookworm) prints every OR-alternative as its own UNMARKED
# 'Depends:' line, so a walker cannot tell alternatives apart - both
# branches of `libsystemd0 | libelogind0` entered the closure as a
# Conflicts pair and apt refused the whole download transaction (E:
# Unable to correct problems), staging zero debs. The solver cannot have
# that problem: simulating against an EMPTY dpkg status means apt sees
# nothing installed and plans the complete closure from the base image's
# state - alternatives collapsed to one branch, virtual providers
# resolved, Essential packages included, exactly what the build-time
# install will want.
apt_resolve_closure() {
  APT_ALL=
  APT_ORDER=
  APT_SCHEDULE=
  _roots=$(apt_manifest_pkgs | tr '\n' ' ') || return 1
  _status=$(mktemp "${TMPDIR:-/tmp}/apt-status.XXXXXX")
  _tmp=$(mktemp "${TMPDIR:-/tmp}/apt-closure.XXXXXX")
  : >"$_status"
  if ! apt-get -o Dir::State::status="$_status" -s install -y \
        --no-install-recommends $_roots >"$_tmp" 2>/dev/null; then
    rm -f "$_tmp" "$_status"
    echo "FATAL: apt-get simulate failed (apt lists present? populate runs apt-get update first)" >&2
    return 1
  fi
  # Walk Inst (unpack) and Conf (configure) lines in apt's plan order: the
  # interleaving IS the install schedule. Only Inst lines join the closure;
  # Conf lines become configure checkpoints in APT_SCHEDULE - dpkg refuses
  # to unpack a package whose Pre-Depends is merely unpacked, so the
  # configure steps are load-bearing.
  _conf=
  while IFS= read -r _line; do
    case "$_line" in
      'Inst '*) _op=u; _rest=${_line#'Inst '} ;;
      'Conf '*) _op=c; _rest=${_line#'Conf '} ;;
      *) continue ;;
    esac
    _n=${_rest%% *}             # first field: the package name
    _n=${_n%%:*}                # strip a multi-arch ':arch' suffix (':' is illegal in names)
    [ -n "$_n" ] || continue
    if [ "$_op" = u ]; then
      case "
$APT_ALL
" in *"
$_n
"*) continue ;; esac
      APT_ORDER="$APT_ORDER$_n
"
      APT_ALL="$APT_ALL$_n
"
    else
      case "
$_conf
" in *"
$_n
"*) continue ;; esac
      _conf="$_conf$_n
"
    fi
    APT_SCHEDULE="$APT_SCHEDULE$_op $_n
"
  done <"$_tmp"
  rm -f "$_tmp" "$_status"
  [ -n "$APT_ALL" ] || { echo "FATAL: apt simulate planned no packages" >&2; return 1; }
}

# Write store/apt/install-order.txt: the plan schedule as replayable ops -
# "u <deb-base-name>" (dpkg --unpack) and "c <pkg-name>" (dpkg --configure)
# in apt's own interleaved order, #-prefixed header. Consumed by
# apt-install.sh: Pre-Depends must see the prerequisite CONFIGURED when the
# dependent is unpacked, so configure checkpoints are kept between unpack
# steps. Every unpack op must map to a staged deb - a name without one
# means resolution was incomplete; failing HERE is cheap, failing at build
# time is not. Deb names are <name>_<version>_<arch>.deb; apt stages exactly
# one candidate version per name into the fresh staging dir, so the sort
# below only disambiguates unexpected leftovers.
apt_write_install_order() { # $1 = staging dir with debs, $2 = output file
  _stage=$1
  _outf=$2
  _body=
  _missing=0
  _schedf=$(mktemp "${TMPDIR:-/tmp}/apt-sched.XXXXXX")
  printf '%s\n' "${APT_SCHEDULE:-}" >"$_schedf"
  while IFS= read -r _line; do
    [ -n "$_line" ] || continue
    _op=${_line%% *}
    _n=${_line#* }
    if [ "$_op" = u ]; then
      _deb=$(ls "$_stage/${_n}_"*.deb 2>/dev/null | LC_ALL=C sort | tail -n 1)
      if [ -z "$_deb" ]; then
        echo "FATAL: no .deb staged for closure package $_n (resolution incomplete?)" >&2
        _missing=1
        continue
      fi
      _line="u ${_deb##*/}"
    fi
    _body="$_body$_line
"
  done <"$_schedf"
  rm -f "$_schedf"
  if [ "$_missing" -ne 0 ]; then
    echo "FATAL: apt closure incomplete - store apt tier NOT updated" >&2
    return 1
  fi
  if [ -z "$_body" ]; then
    echo "FATAL: apt schedule is empty - store apt tier NOT updated" >&2
    return 1
  fi
  {
    printf '%s\n' "# install schedule for store/apt/*.deb (u=dpkg --unpack, c=dpkg --configure)"
    printf '%s\n' "# written by populate-preinstall.sh from apt's plan (Inst/Conf interleaved);"
    printf '%s\n' "# consumed by apt-install.sh at build time. Regenerated on every apt fetch."
    printf '%s' "$_body"
  } >"$_outf"
}

# Skip-path guard: true when the store already covers the CURRENT manifest
# (schedule-v2 order present AND every manifest package has a deb). The apt
# analogue of same_version_in_store - a store built from an older manifest
# self-heals on the next populate run instead of staying stale forever.
apt_store_covers_manifest() {
  _ord=$STORE_DIR/apt/install-order.txt
  [ -f "$_ord" ] || return 1
  # Schedule-v2 guard: a v1 order file (bare deb names, unpack-only) fails
  # Pre-Depends at dpkg time; a v1 store self-heals by re-staging on the
  # next populate run instead of being trusted forever.
  grep -q '^u ' "$_ord" || return 1
  _pkgs=$(apt_manifest_pkgs) || return 1
  for _p in $_pkgs; do
    ls "$STORE_DIR/apt/${_p}_"*.deb >/dev/null 2>&1 || return 1
  done
  return 0
}

# Fetch the full closure into a staging dir, write the install schedule,
# then swap it in. store/apt/*.deb is REGENERATED per fetch - one closure,
# one consistent version set (two versions of a package in one dpkg
# transaction are a hard error) - while the pip/npm tiers keep their
# add-only dependency policy. Requires root and network (populate tier).
fetch_apt_debs() {
  _stage="$STORE_DIR/apt/.staging.$$"
  rm -rf "$_stage"
  mkdir -p "$_stage/partial"
  apt-get update
  _roots=$(apt_manifest_pkgs | tr '\n' ' ') || return 1
  _status=$(mktemp "${TMPDIR:-/tmp}/apt-status.XXXXXX")
  : >"$_status"
  # Same solver inputs as apt_resolve_closure (manifest roots + empty dpkg
  # status) -> the download stages exactly the planned closure. apt gets
  # ONLY the roots: building the closure is the solver's job - the old
  # hand-built list shipped conflicting OR-alternatives and apt staged
  # nothing. Nothing is 'installed' in the empty status, so --reinstall
  # is neither needed nor possible.
  if ! apt-get -o Dir::State::status="$_status" install -y \
        --no-install-recommends --download-only \
        -o Dir::Cache::archives="$_stage" $_roots; then
    rm -f "$_status"
    rm -rf "$_stage"
    echo "FATAL: apt-get download of the apt closure failed (see apt error above)" >&2
    return 1
  fi
  rm -f "$_status"
  apt_write_install_order "$_stage" "$STORE_DIR/apt/install-order.txt" || {
    rm -rf "$_stage"
    return 1
  }
  rm -f "$STORE_DIR"/apt/*.deb
  mv "$_stage"/*.deb "$STORE_DIR/apt/"
  rm -rf "$_stage"
}
