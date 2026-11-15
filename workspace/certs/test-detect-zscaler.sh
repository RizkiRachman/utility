#!/bin/sh
# certs/test-detect-zscaler.sh - unit tests for the cert-detector pure
# functions via the sourced mode (ZSHARED=1). No network: synthetic certs
# are generated locally with openssl req -x509. Filesystem assertions.
set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PASS=0; FAIL=0
WORK=$(mktemp -d)
cleanup() { rm -rf "$WORK"; }
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
gen_cert() {
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 -keyout "$1.key" -out "$1.crt" -subj "$2" >/dev/null 2>&1
}
count_files() { ls "$1" 2>/dev/null | grep -c "crt$" || true; }
gen_cert "$WORK/zroot" "/CN=Zscaler Root CA/O=Zscaler Inc/C=US"
gen_cert "$WORK/other" "/CN=Example Intermediate CA/O=Example Corp/C=US"
ZSHARED=1
export ZSHARED
. "$SCRIPT_DIR/detect-zscaler.sh"
PREFIX="${AUTODETECTED_PREFIX:-zscaler-autodetected-}"
out="$WORK/out1"; mkdir -p "$out"
cat "$WORK/zroot.crt" > "$WORK/chain1.pem"
extract_zscaler_certs "$WORK/chain1.pem" "$out" 2>/dev/null
if [ "$(count_files "$out")" -ge 1 ]; then pass "self-signed zscaler root extracted"; else fail "zscaler root not extracted"; fi
found=$(ls "$out" 2>/dev/null | grep -c "^$PREFIX" || true)
if [ "$found" -ge 1 ]; then pass "output uses the autodetected prefix"; else fail "wrong prefix in output"; fi
out2="$WORK/out2"; mkdir -p "$out2"
cat "$WORK/other.crt" > "$WORK/chain2.pem"
extract_zscaler_certs "$WORK/chain2.pem" "$out2" 2>/dev/null
if [ "$(count_files "$out2")" -eq 0 ]; then pass "non-zscaler chain ignored"; else fail "non-zscaler cert extracted"; fi
out3="$WORK/out3"; mkdir -p "$out3"; cp "$WORK/zroot.crt" "$out3/manual-root.crt"
cat "$WORK/zroot.crt" > "$WORK/chain3.pem"
extract_zscaler_certs "$WORK/chain3.pem" "$out3" 2>/dev/null
if [ "$(count_files "$out3")" -eq 1 ]; then pass "fingerprint dedupe suppresses manual duplicate"; else fail "dedupe failed (manual dup re-extracted)"; fi
cleanup
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
