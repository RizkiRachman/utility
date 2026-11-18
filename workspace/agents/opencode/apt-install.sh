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
#      matches the build architecture: one dpkg -i transaction in the
#      deps-first order recorded by populate-preinstall.sh in
#      store/apt/install-order.txt. No apt-get update, no network, no
#      apt-get upgrade.
#   2. NETWORK - store absent / partial / wrong-arch / dpkg failure:
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
  # The /var/lib/apt cache mount is SHARED across builds: a build interrupted
  # mid-update leaves a truncated Packages index there, later builds Hit the
  # cached InRelease (unchanged), skip re-downloading Packages, and install
  # fails with 'Unable to locate package' for every name. Self-heal: purge
  # the lists out of the cache mount, re-update from scratch, retry once.
  # Zero cost in the healthy path.
  # After a failed offline dpkg this also repairs the half-installed state
  # (apt resolves the manifest against whatever dpkg left behind).
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
if [ -f "$order_file" ]; then
  echo "apt install: deps-first order from install-order.txt ($(grep -cvE '^[[:space:]]*(#|$)' "$order_file" || true) entries)"
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
