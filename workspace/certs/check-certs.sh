#!/bin/sh
# certs/check-certs.sh - CI gate (S2/P2-13): every .crt under the certs dirs
# must match the tracked allowlist (certs-allowlist.txt). Unexpected files
# fail the check - a dropped-in CA cannot silently become trusted.
# Mirrors are checked only if present.
set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ALLOWLIST="$SCRIPT_DIR/certs-allowlist.txt"
fail=0; n=0
[ -f "$ALLOWLIST" ] || { echo "FAIL: allowlist missing: $ALLOWLIST" >&2; exit 1; }
check_dir() {
  d=$1
  # L4: a silently-skipped missing dir lets a RENAMED dir pass undetected -
  # warn loudly (a missing submodule mirror is normal pre-sync; a missing
  # parent certs/ dir is not). Still non-fatal here: this script is the
  # tracked-inventory sanity check; the enforcing call runs at the end of
  # sync-certs.sh where certs actually land.
  if [ ! -d "$d" ]; then
    echo "WARN: cert dir missing (renamed? not yet created?): $d - nothing checked there" >&2
    return 0
  fi
  for f in "$d"/*.crt; do
    [ -f "$f" ] || continue
    n=$((n + 1)); base=$(basename "$f"); ok=0
    while IFS= read -r pat; do
      case "$pat" in ""|\#*) continue ;; esac
      case "$base" in
        $pat) ok=1; break ;;
      esac
    done < "$ALLOWLIST"
    if [ "$ok" -ne 1 ]; then
      echo "FAIL: unexpected cert file: $f (add to certs-allowlist.txt or remove)" >&2
      fail=1
    fi
  done
}
check_dir "$SCRIPT_DIR"
check_dir "$SCRIPT_DIR/../agents/opencode/certs"
check_dir "$SCRIPT_DIR/../agents/openui/app/certs"
echo "certs allowlist check: $n file(s) checked"
exit $fail
