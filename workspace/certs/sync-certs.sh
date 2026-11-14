#!/bin/sh
# Mirror the workspace-root certs/ into every submodule cert dir (single source).
#
# certs/ at the workspace root is the ONLY place certs are kept and rotated:
# detect-zscaler.sh seeds it, manual certs land here, and this script mirrors
# the exact parent set into the submodule cert dirs right before docker
# builds (the Dockerfiles COPY certs/ from the submodule dirs). Targets are
# exact mirrors: every parent *.crt is copied down, every target *.crt not in
# the parent is removed - submodule copies can never drift from the source.
# .gitkeep / .gitignore files in the targets are untouched.
#
# SEED-THEN-MIRROR: when the parent certs/ holds no *.crt at all (fresh
# checkout), the detector runs first to seed the parent:
#   exit 0  interception found  -> mirror the fresh autodetected set
#   exit 1  no interception     -> mirror whatever manual certs exist
#                                  (possibly none - targets are cleaned out)
#   exit 2  environment failure -> abort; nothing deleted, nothing copied
#
# populate-preinstall.sh calls this after its own detector run, so submodule
# placeholders refresh on every store population.
#
# Usage: sh sync-certs.sh
# Exit 0 = parent set mirrored to all targets (empty parent allowed)
# Exit 1 = seeding failed (detector environment error) - targets untouched
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

# Count the parent certs without relying on nullglob (POSIX sh).
parent_certs() {
  _n=0
  for _crt in "$SCRIPT_DIR"/*.crt; do
    [ -f "$_crt" ] && _n=$((_n + 1))
  done
  echo "$_n"
}

# SEED: parent empty -> probe the live wire once and let the detector fill it.
if [ "$(parent_certs)" -eq 0 ]; then
  echo "==> certs/ empty - seeding from the live wire (detect-zscaler.sh)"
  set +e
  sh "$SCRIPT_DIR/detect-zscaler.sh" "$SCRIPT_DIR"
  _rc=$?
  set -e
  if [ "$_rc" -eq 2 ]; then
    echo "ERROR: cert seeding failed (environment error, exit $_rc) - aborting, targets untouched" >&2
    exit 1
  fi
  if [ "$_rc" -eq 0 ]; then
    echo "==> interception found - fresh autodetected set seeded"
  else
    echo "==> no TLS interception (exit $_rc) - mirroring manual certs only"
  fi
fi

# MIRROR: exact parent set into each target; stale target certs are removed.
for d in "$REPO_ROOT/agents/opencode/certs" "$REPO_ROOT/agents/openui/app/certs"; do
  [ -d "$d" ] || mkdir -p "$d"
  _removed=0
  for _crt in "$d"/*.crt; do
    [ -f "$_crt" ] || continue
    rm -f "$_crt"
    _removed=$((_removed + 1))
  done
  _copied=0
  for _crt in "$SCRIPT_DIR"/*.crt; do
    [ -f "$_crt" ] || continue
    cp -f "$_crt" "$d"/
    _copied=$((_copied + 1))
  done
  echo "==> $d: ${_copied} certs mirrored (${_removed} stale removed)"
done

echo "==> sync complete: $(parent_certs) cert(s) mirrored to all submodule cert dirs"
