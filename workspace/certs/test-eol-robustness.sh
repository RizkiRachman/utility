#!/bin/sh
# certs/test-eol-robustness.sh - proves the CRLF defenses work end to end:
# scripts and the allowlist saved with Windows \r line endings (the historical
# dash killer: `set -eu\r` became option "u\r") must still pass the allowlist
# gate and the sync. No network, no real certs: a fake workspace tree is
# built in a mktemp sandbox, the copies are CRLF-mangled on purpose, then the
# real scripts run against them.
set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PASS=0; FAIL=0
WORK=$(mktemp -d)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT HUP INT TERM
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
# Append \r to every line. awk, not `sed 's/$/\r/'`: BSD/macOS sed does not
# support \r escapes, and this test must itself run on macOS and Git Bash.
crlf() { awk '{printf "%s\r\n", $0}' "$1" > "$1.crlf" && mv "$1.crlf" "$1"; }

# Fake repo in the layout sync-certs.sh/check-certs.sh expect relative to $0.
REPO="$WORK/repo"
mkdir -p "$REPO/certs" "$REPO/agents/opencode/certs" "$REPO/agents/openui/app/certs"
cp "$SCRIPT_DIR/check-certs.sh" "$SCRIPT_DIR/sync-certs.sh" "$REPO/certs/"
cp "$SCRIPT_DIR/certs-allowlist.txt" "$REPO/certs/"
# The stale mirror cert keeps an ALLOWLISTED name: pre-sync, the gate checks
# the mirror dirs too, and a stale-but-allowlisted copy must pass the gate
# while the sync still removes it (exact-mirror semantics are allowlist
# agnostic - only the parent set survives).
echo "extra.crt" >> "$REPO/certs/certs-allowlist.txt"
# Dummy cert: the NAME matches the allowlist glob; content is irrelevant here.
echo "dummy cert content - irrelevant to these scripts" > "$REPO/certs/zscaler-autodetected-1.crt"
# Stale mirror cert: sync must remove it from every target dir.
echo "stale cert that sync must remove" > "$REPO/agents/opencode/certs/extra.crt"
echo "stale cert that sync must remove" > "$REPO/agents/openui/app/certs/extra.crt"

# Mangle exactly what a Windows checkout mangles: both entry scripts and the
# allowlist. detect-zscaler.sh stays LF - the dummy parent cert means the
# seeding probe never fires and the test never touches the network.
crlf "$REPO/certs/check-certs.sh"
crlf "$REPO/certs/sync-certs.sh"
crlf "$REPO/certs/certs-allowlist.txt"

# a. CI gate exits 0 despite the mangled script + allowlist: the line-2
#    self-heal guard re-execs an LF copy, and the gate reads the allowlist
#    from a tr -d '\r' temp copy (D3).
if sh "$REPO/certs/check-certs.sh" > "$WORK/check.out" 2>&1; then
  pass "check-certs.sh exits 0 on CRLF-mangled script + allowlist"
else
  fail "check-certs.sh failed on CRLF input:"
  cat "$WORK/check.out" >&2
fi

# b. Sync exits 0, mirrors the 1 parent cert, cleans the stale extra.crt
#    out of both mirror dirs.
if sh "$REPO/certs/sync-certs.sh" > "$WORK/sync.out" 2>&1; then
  pass "sync-certs.sh exits 0 on CRLF-mangled script + allowlist"
else
  fail "sync-certs.sh failed on CRLF input:"
  cat "$WORK/sync.out" >&2
fi
for d in "$REPO/agents/opencode/certs" "$REPO/agents/openui/app/certs"; do
  if [ ! -f "$d/extra.crt" ] && [ -f "$d/zscaler-autodetected-1.crt" ]; then
    pass "mirror refreshed: stale extra.crt removed, 1 cert mirrored ($d)"
  else
    fail "mirror wrong in $d (extra.crt must be gone, zscaler-autodetected-1.crt present)"
  fi
done

cleanup
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
