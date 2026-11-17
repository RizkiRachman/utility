#!/bin/sh
grep -q "$(printf '\r')" "$0" 2>/dev/null && { tr -d '\r' < "$0" > "${0%/*}/.$(basename "$0").$$.lf" && exec sh "${0%/*}/.$(basename "$0").$$.lf" "$@"; } # CRLF self-heal: re-exec an LF copy of this script from its own dir when Windows line endings are detected
# certs/test-detect-zscaler.sh - unit tests for the cert-detector pure
# functions via the sourced mode (ZSHARED=1). No network: synthetic certs
# are generated locally with openssl req -x509. Filesystem assertions.
set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PASS=0; FAIL=0
WORK=$(mktemp -d)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT HUP INT TERM
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
# LEAF FILTER: pass-2 stores only zscaler-CN, CA:TRUE certs. Two leaf kinds
# must be rejected: website-CN leaves (github.com) and zscaler-domain leaves
# (*.zscloud.net - passes the CN test, still CA:FALSE and 2-week-lived).
gen_signed() {
  _b=$1; _s=$2; _ca=$3; _ext=$4; _ser=$5
  openssl req -new -newkey rsa:2048 -nodes -keyout "$WORK/$_b.key" \
    -out "$WORK/$_b.csr" -subj "$_s" >/dev/null 2>&1
  printf '%s\n' "$_ext" > "$WORK/$_b.ext"
  openssl x509 -req -in "$WORK/$_b.csr" -CA "$WORK/$_ca.crt" -CAkey "$WORK/$_ca.key" \
    -set_serial "$_ser" -days 2 -out "$WORK/$_b.crt" -extfile "$WORK/$_b.ext" >/dev/null 2>&1
}
gen_signed leaf1 "/CN=github.com/O=Zscaler Inc/C=US" zroot "basicConstraints=critical,CA:FALSE" 101
gen_signed leafz "/CN=*.zscloud.net/O=Zscaler Inc/C=US" zroot "basicConstraints=critical,CA:FALSE" 103
gen_signed int1 "/CN=Zscaler Intermediate Root CA/O=Zscaler Inc/C=US" zroot "basicConstraints=critical,CA:TRUE" 102
out4="$WORK/out4"; mkdir -p "$out4"
# wire order: leaves first, like a real zscaler chain
cat "$WORK/leaf1.crt" "$WORK/leafz.crt" "$WORK/int1.crt" > "$WORK/chain4.pem"
extract_zscaler_certs "$WORK/chain4.pem" "$out4" 2>/dev/null
if [ "$(count_files "$out4")" -eq 1 ]; then
  SUBJ4=$(openssl x509 -in "$out4"/*.crt -noout -subject 2>/dev/null)
  case "$SUBJ4" in
    *Intermediate*) pass "leaves (website CN and zscaler-CN CA:FALSE) skipped, CA:TRUE intermediate captured" ;;
    *) fail "leaf filter broken: stored $SUBJ4" ;;
  esac
else
  fail "leaf filter: expected 1 stored cert, got $(count_files "$out4")"
fi

cleanup
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
