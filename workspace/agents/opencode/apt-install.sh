#!/bin/sh
# apt-install.sh - offline-first base-packages install for the opencode
# image build (consumed by the Dockerfile base-packages RUN; kept as a file
# so test-apt-offline.sh can exercise the gating logic without docker).
#
# Usage: apt-install.sh <packages-apt.txt> <store-apt-dir>
#
# Tiers, mirroring the npm/pip/bin store-first pattern - builds never
# silently change behavior, every fallback logs loudly:
#   1. OFFLINE - the store holds debs, covers every manifest package, and
#      matches the build architecture: apt's plan schedule from
#      store/apt/install-order.txt is replayed step by step (dpkg --unpack
#      / dpkg --configure, interleaved the way apt itself interleaves them
#      - Pre-Depends need the prerequisite CONFIGURED at unpack time).
#      No apt-get update, no network, no apt-get upgrade.
#   2. NETWORK - store absent / partial / wrong-arch / replay failure:
#      apt-get update + apt-get install of exactly the manifest packages
#      (pre-install/packages-apt.txt is the single source of truth shared
#      with the populate-side closure resolution in apt-closure.sh).
#
# TOFU window: first-fetch debs are unverified until the maintainer's
# --update-digests run records pins (same caveat as every store tier); the
# Dockerfile digest gate re-hashes the store once pins exist.
set -eu

manifest=$1
store=$2

manifest_pkgs() {
  # A Windows checkout can carry this manifest with CRLF (git autocrlf; the
  # .gitattributes pin only fixes fresh checkouts, not existing trees).
  # 'git\r' exists in no apt index -> 'Unable to locate package' for every
  # line. Strip CR at the source so names are clean whatever the checkout did.
  tr -d '\r' < "$manifest" | grep -vE '^[[:space:]]*(#|$)'
}
pkg_count=$(manifest_pkgs | wc -l | tr -d ' ')
if [ "$pkg_count" -eq 0 ]; then
  echo "FATAL: apt manifest $manifest resolved to 0 packages (empty, all comments, or unreadable)" >&2
  exit 1
fi

network_install() {
  echo "apt install: NETWORK tier - apt-get update + install of ${pkg_count} manifest package(s) from $manifest"
  apt-get update
  # A failed offline replay leaves half-installed packages in dpkg's status
  # (unpacked but unconfigured) and a plain manifest install then fails on
  # the residue's Pre-Depends. Repair first: configure everything unpacked,
  # then let apt -f resolve what remains.
  DEBIAN_FRONTEND=noninteractive dpkg --configure -a || true
  DEBIAN_FRONTEND=noninteractive apt-get -f install -y --no-install-recommends
  # The /var/lib/apt cache mount is SHARED across builds: a build interrupted
  # mid-update leaves a truncated Packages index there, later builds Hit the
  # cached InRelease (unchanged), skip re-downloading Packages, and install
  # fails with 'Unable to locate package' for every name. Self-heal: purge
  # the lists out of the cache mount, re-update from scratch, retry once.
  # Zero cost in the healthy path.
  # shellcheck disable=SC2086
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $(manifest_pkgs) || {
    echo "apt install failed on the shared lists cache - purging stale indexes and retrying once" >&2
    rm -rf /var/lib/apt/lists/*
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $(manifest_pkgs)
  }
  update-ca-certificates
  git config --system --add safe.directory '*'
}

# --- tier gate -------------------------------------------------------------

if ! ls "$store"/*.deb >/dev/null 2>&1; then
  echo "apt install: no .deb in store ($store) - network tier"
  network_install
  exit 0
fi

# Arch guard: a store populated on another machine can carry debs for a
# different dpkg architecture (cross builds); dpkg would reject them at
# unpack time, so fall back to the network tier loudly instead. Arch-all
# debs (e.g. pipx) carry no arch constraint and are skipped when picking
# the representative.
build_arch=$(dpkg --print-architecture)
store_arch=
for f in "$store"/*.deb; do
  a=${f##*/}
  a=${a##*_}
  a=${a%.deb}
  if [ "$a" != all ]; then
    store_arch=$a
    break
  fi
done
if [ -n "$store_arch" ] && [ "$store_arch" != "$build_arch" ]; then
  echo "apt install: store arch $store_arch != build arch $build_arch (wrong-arch store; re-populate on the build host) - network tier"
  network_install
  exit 0
fi

# Coverage gate: every manifest package must have its deb in the store,
# otherwise the offline transaction would produce a half-installed image.
missing=
for p in $(manifest_pkgs); do
  ls "$store/${p}_"*.deb >/dev/null 2>&1 || missing="$missing $p"
done
if [ -n "$missing" ]; then
  echo "apt install: store missing deb(s) for:$missing - network tier (re-run populate-preinstall.sh to refresh the store)"
  network_install
  exit 0
fi

deb_count=$(ls "$store"/*.deb | wc -l | tr -d ' ')
echo "apt install: OFFLINE - ${deb_count} deb(s) from $store (no apt-get update, no network)"
order_file=$store/install-order.txt
offline_ok=0
if [ -f "$order_file" ] && grep -q '^u ' "$order_file"; then
  # Schedule replay: u=dpkg --unpack, c=dpkg --configure, in apt's plan
  # order. The configure checkpoints are the point: dpkg refuses to unpack
  # a package whose Pre-Depends is merely unpacked, and apt plans the Conf
  # lines exactly where they must run.
  echo "apt install: deps-first schedule from install-order.txt ($(grep -c '^u ' "$order_file") unpack, $(grep -c '^c ' "$order_file") configure step(s))"
  _fail=
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    _op=${line%% *}
    _arg=${line#* }
    case "$_op" in
      u)
        DEBIAN_FRONTEND=noninteractive dpkg --unpack "$store/$_arg" || { _fail="unpack $_arg"; break; }
        ;;
      c)
        DEBIAN_FRONTEND=noninteractive dpkg --configure "$_arg" || { _fail="configure $_arg"; break; }
        ;;
      *)
        _fail="malformed schedule line: $line"
        break
        ;;
    esac
  done <"$order_file"
  if [ -z "$_fail" ]; then
    # Safety net: anything the schedule left half-configured is a defect.
    DEBIAN_FRONTEND=noninteractive dpkg --configure -a || _fail="dpkg --configure -a"
  fi
  if [ -n "$_fail" ]; then
    echo "apt install: OFFLINE schedule failed at: $_fail"
  else
    offline_ok=1
  fi
elif [ -f "$order_file" ]; then
  # Legacy store (v1 order file: bare deb names, unpack-only, no schedule):
  # one dpkg -i transaction - a Pre-Depends mis-order fails and lands in
  # the repair tier below; populate re-stages to schedule v2 on the next
  # run (the store-skip guard requires v2).
  echo "WARN: v1 install-order.txt in $store (no u/c schedule) - single dpkg -i transaction, Pre-Depends may fail"
  set --
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    set -- "$@" "$store/$line"
  done <"$order_file"
  if DEBIAN_FRONTEND=noninteractive dpkg -i "$@"; then
    offline_ok=1
  fi
else
  # Legacy store (debs without the recorded order): one dpkg transaction in
  # alphabetical order - dpkg defers configuration, so only a Pre-Depends
  # mis-order can fail, and the failure lands in the repair tier below.
  echo "WARN: install-order.txt missing in $store (legacy store) - alphabetical fallback"
  if DEBIAN_FRONTEND=noninteractive dpkg -i "$store"/*.deb; then
    offline_ok=1
  fi
fi
if [ "$offline_ok" -ne 1 ]; then
  echo "apt install: OFFLINE install FAILED (broken or partial store) - repairing over the network tier"
  network_install
  exit 0
fi

update-ca-certificates
git config --system --add safe.directory '*'
echo "apt install: OFFLINE complete - manifest packages installed from the store"
