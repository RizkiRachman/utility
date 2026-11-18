#!/bin/sh
grep -q "$(printf '\r')" "$0" 2>/dev/null && { tr -d '\r' < "$0" > "${0%/*}/.$(basename "$0").$$.lf" && exec sh "${0%/*}/.$(basename "$0").$$.lf" "$@"; } # CRLF self-heal: re-exec an LF copy of this script from its own dir when Windows line endings are detected
# test-apt-offline.sh - unit tests for the offline apt tier. Pure shell, no
# network, no root, no docker: mock apt-get/dpkg/update-ca-
# certificates/git binaries on a PATH shim, then drive the real functions
# from apt-closure.sh (sourced) and the real apt-install.sh (executed).
# Filesystem + mock-log assertions, mirroring certs/test-detect-zscaler.sh.
set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PASS=0; FAIL=0
WORK=$(mktemp -d "${TMPDIR:-/tmp}/apt-offline-test.XXXXXX")
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT HUP INT TERM
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
assert() { # assert <desc> <actual> <expected>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got: $2, want: $3)"; fi
}
assert_contains() { # assert_contains <desc> <haystack> <needle>
  case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing: $3 in: $2)" ;; esac
}

# --- mocks ------------------------------------------------------------------
MOCKDIR=$WORK/bin
mkdir -p "$MOCKDIR"
MOCK_LOG=$WORK/mock.log
: >"$MOCK_LOG"
export MOCK_LOG

cat > "$MOCKDIR/apt-get" <<'EOF'
#!/bin/sh
echo "apt-get $*" >> "$MOCK_LOG"
case "$1" in update) exit 0 ;; esac
_sim=0; _dl=0; _dir=
for a in "$@"; do
  case "$a" in
    -s) _sim=1 ;;
    --download-only) _dl=1 ;;
    -o) : ;;
    Dir::State::status=*) : ;;
    Dir::Cache::archives=*) _dir=${a#Dir::Cache::archives=} ;;
    install|-y|--no-install-recommends|--reinstall) : ;;
    *) : ;;  # manifest roots - the solver expands them, not the mock
  esac
done
if [ "$_sim" = "1" ]; then
  [ "${MOCK_SIM_RC:-0}" = "0" ] || exit "$MOCK_SIM_RC"
  cat "$MOCK_PLAN"
  exit 0
fi
if [ "$_dl" = "1" ]; then
  # same solver inputs -> stages exactly the planned closure
  mkdir -p "$_dir/partial"
  for n in $(sed -n 's/^Inst \([^ ]*\).*/\1/p' "$MOCK_PLAN"); do
    printf 'deb' > "$_dir/${n}_1.0-1_amd64.deb"
  done
fi
exit 0
EOF

cat > "$MOCKDIR/dpkg" <<'EOF'
#!/bin/sh
echo "dpkg $*" >> "$MOCK_LOG"
case "$1" in
  --print-architecture) echo "${MOCK_DPKG_ARCH:-amd64}" ;;
  -i)
    if [ "${MOCK_DPKG_RC:-0}" != "0" ]; then
      echo "mock dpkg: simulated failure" >&2
      exit "$MOCK_DPKG_RC"
    fi
    ;;
esac
exit 0
EOF

for m in update-ca-certificates git; do
  printf '#!/bin/sh\necho "%s $*" >> "$MOCK_LOG"\nexit 0\n' "$m" > "$MOCKDIR/$m"
done
chmod +x "$MOCKDIR"/*
# PATH shim: the mocks MUST shadow the real apt/dpkg tools for every
# sourced function and every apt-install.sh invocation below.
export PATH="$MOCKDIR:$PATH"

# --- sourced module under test ---------------------------------------------
SCRIPT_DIR_SAVE=$SCRIPT_DIR
SCRIPT_DIR=$WORK                    # apt-closure.sh derives APT_MANIFEST from it
APT_MANIFEST=$WORK/manifest.txt     # explicit, env wins
STORE_DIR=$WORK/store
. "$SCRIPT_DIR_SAVE/apt-closure.sh"
SCRIPT_DIR=$SCRIPT_DIR_SAVE

write_manifest() { # write_manifest <names...>
  {
    echo "# manifest (test)"
    for n in "$@"; do echo "$n"; done
  } >"$APT_MANIFEST"
}

# --- 1. manifest parsing ----------------------------------------------------
write_manifest app libb
n=$(apt_manifest_pkgs | grep -c .)
assert "manifest: comments and blanks stripped" "$n" "2"
printf '# only comments\n\n' >"$APT_MANIFEST"
if apt_manifest_pkgs >/dev/null 2>&1; then fail "manifest: comments-only must fail"; else pass "manifest: comments-only must fail"; fi
APT_MISSING=$WORK/nope.txt
APT_MANIFEST_SAVE=$APT_MANIFEST; APT_MANIFEST=$APT_MISSING
if apt_manifest_pkgs >/dev/null 2>&1; then fail "manifest: missing file must fail"; else pass "manifest: missing file must fail"; fi
APT_MANIFEST=$APT_MANIFEST_SAVE

# --- 2. closure via apt's solver (empty-status simulation) ------------------
MOCK_PLAN=$WORK/plan.txt
export MOCK_PLAN
cat >"$MOCK_PLAN" <<'EOF'
Inst liba (1.0-1 Debian:12/bookworm [amd64])
Inst alt1 (1.0-1 Debian:12/bookworm [amd64])
Inst libb (1.0-1 Debian:12/bookworm [amd64])
Inst app (1.0-1 Debian:12/bookworm [amd64])
EOF
write_manifest app
if apt_resolve_closure; then pass "closure: resolver runs"; else fail "closure: resolver runs"; fi
assert "closure: members in apt's plan order (APT_ORDER)" "$APT_ORDER" "liba
alt1
libb
app
"
assert "closure: APT_ALL mirrors APT_ORDER" "$APT_ALL" "$APT_ORDER"

# regression (populate failure 2026-11-18): apt-cache depends prints every
# OR-alternative as its own unmarked 'Depends:' line, so the old walk added
# BOTH branches (libsystemd0 AND libelogind0 - a Conflicts pair) and apt
# staged nothing. The solver set must be authoritative: nothing added.
cat >"$MOCK_PLAN" <<'EOF'
Inst libsystemd0 (255.4-1 Debian:12/bookworm [amd64])
Inst libc6 (2.36-9+deb12u7 Debian:12/bookworm [amd64])
Inst procps (2:4.0.2-3 Debian:12/bookworm [amd64])
EOF
write_manifest procps
apt_resolve_closure
assert "closure: exactly the planned set" "$(printf '%s' "$APT_ALL" | grep -c .)" "3"
case "$APT_ALL" in
  *libelogind0*) fail "closure: no walk-added alternatives (Conflicts pair)" ;;
  *) pass "closure: no walk-added alternatives (Conflicts pair)" ;;
esac

# multi-arch Inst names and duplicate Inst lines
cat >"$MOCK_PLAN" <<'EOF'
Inst libc6 (2.36-9+deb12u7 Debian:12/bookworm [amd64])
Inst pipx:amd64 (1.4.0-1 Debian:12/bookworm [amd64])
Inst libc6 (2.36-9+deb12u7 Debian:12/bookworm [amd64])
EOF
write_manifest pipx
apt_resolve_closure
assert "closure: dedup + ':arch' stripped" "$APT_ORDER" "libc6
pipx
"

# simulate failure -> loud FATAL, resolver fails
MOCK_SIM_RC=100
export MOCK_SIM_RC
write_manifest app
cat >"$MOCK_PLAN" <<'EOF'
Inst app (1.0-1 Debian:12/bookworm [amd64])
EOF
if apt_resolve_closure 2>"$WORK/simfail.err"; then fail "closure: sim failure must fail"; else pass "closure: sim failure must fail"; fi
assert_contains "closure: sim failure FATAL message" "$(cat "$WORK/simfail.err")" "apt-get simulate failed"
unset MOCK_SIM_RC

# --- 3. fetch_apt_debs end-to-end (staging, order file, regen) ---------------
cat >"$MOCK_PLAN" <<'EOF'
Inst liba (1.0-1 Debian:12/bookworm [amd64])
Inst alt1 (1.0-1 Debian:12/bookworm [amd64])
Inst libb (1.0-1 Debian:12/bookworm [amd64])
Inst app (1.0-1 Debian:12/bookworm [amd64])
EOF
write_manifest app
mkdir -p "$STORE_DIR/apt"
printf 'stale' >"$STORE_DIR/apt/stalepkg_0.9_amd64.deb"
apt_resolve_closure
if fetch_apt_debs 2>"$WORK/fetch.err"; then pass "fetch: runs end-to-end"; else fail "fetch: runs end-to-end ($(cat "$WORK/fetch.err"))"; fi
assert "fetch: stale deb regenerated away" "$(ls "$STORE_DIR/apt/stalepkg_"* 2>/dev/null | wc -l | tr -d ' ')" "0"
assert "fetch: 4 debs in store" "$(ls "$STORE_DIR/apt/"*.deb 2>/dev/null | grep -c .)" "4"
assert "fetch: staging dir removed" "$(ls -d "$STORE_DIR"/apt/.staging.* 2>/dev/null | wc -l | tr -d ' ')" "0"
order_body=$(grep -v '^#' "$STORE_DIR/apt/install-order.txt" | tr '\n' ' ')
assert "fetch: install-order.txt deps-first" "$order_body" "liba_1.0-1_amd64.deb alt1_1.0-1_amd64.deb libb_1.0-1_amd64.deb app_1.0-1_amd64.deb "
assert_contains "fetch: download-only against an empty dpkg status" "$(cat "$MOCK_LOG")" "Dir::State::status="
dl_line=$(grep -- '--download-only' "$MOCK_LOG" | tail -n 1)
case "$dl_line" in
  *" app"*) pass "fetch: only the manifest roots handed to apt-get" ;;
  *) fail "fetch: only the manifest roots handed to apt-get ($dl_line)" ;;
esac
case "$dl_line" in
  *"liba"*|*"libb"*|*"alt1"*) fail "fetch: hand-built closure list must not reach apt-get" ;;
  *) pass "fetch: hand-built closure list must not reach apt-get" ;;
esac

# --- 4. coverage guard --------------------------------------------------------
write_manifest app libb liba alt1   # full manifest: coverage must reflect every name
if apt_store_covers_manifest; then pass "coverage: complete store covers manifest"; else fail "coverage: complete store covers manifest"; fi
rm -f "$STORE_DIR/apt/liba_"*.deb
if apt_store_covers_manifest; then fail "coverage: missing deb detected"; else pass "coverage: missing deb detected"; fi
mv "$STORE_DIR/apt/install-order.txt" "$WORK/order.bak"
if apt_store_covers_manifest; then fail "coverage: missing order file detected"; else pass "coverage: missing order file detected"; fi
mv "$WORK/order.bak" "$STORE_DIR/apt/install-order.txt"
printf 'deb' >"$STORE_DIR/apt/liba_1.0-1_amd64.deb"   # restore the full store

# --- 5. apt-install.sh tiers --------------------------------------------------
export MOCK_DPKG_ARCH=amd64
write_manifest app libb liba alt1
: >"$MOCK_LOG"
out=$(sh "$SCRIPT_DIR_SAVE/apt-install.sh" "$APT_MANIFEST" "$STORE_DIR/apt" 2>&1)
rc=$?
assert "install: offline tier exits 0" "$rc" "0"
assert_contains "install: offline log line" "$out" "OFFLINE - 4 deb(s)"
dpkg_line=$(grep '^dpkg -i ' "$MOCK_LOG" | tail -n 1)
assert "install: dpkg order follows install-order.txt" "$dpkg_line" "dpkg -i $STORE_DIR/apt/liba_1.0-1_amd64.deb $STORE_DIR/apt/alt1_1.0-1_amd64.deb $STORE_DIR/apt/libb_1.0-1_amd64.deb $STORE_DIR/apt/app_1.0-1_amd64.deb"
case "$(cat "$MOCK_LOG")" in *"apt-get update"*) fail "install: offline tier must not run apt-get update" ;; *) pass "install: offline tier must not run apt-get update" ;; esac

# empty store -> network tier
: >"$MOCK_LOG"
rm -f "$STORE_DIR"/apt/*.deb
out=$(sh "$SCRIPT_DIR_SAVE/apt-install.sh" "$APT_MANIFEST" "$STORE_DIR/apt" 2>&1)
rc=$?
assert "install: empty store still exits 0 (network tier)" "$rc" "0"
assert_contains "install: empty store -> apt-get update" "$(cat "$MOCK_LOG")" "apt-get update"
apt_install_line=$(grep '^apt-get install ' "$MOCK_LOG" | tail -n 1)
case "$apt_install_line" in *"app"*"libb"*) pass "install: network tier installs manifest names" ;; *) fail "install: network tier installs manifest names ($apt_install_line)" ;; esac

# partial store (manifest uncovered) -> network tier, loud
mkdir -p "$STORE_DIR/apt"
printf 'deb' >"$STORE_DIR/apt/app_1.0-1_amd64.deb"
printf 'deb' >"$STORE_DIR/apt/libb_1.0-1_amd64.deb"
: >"$MOCK_LOG"
out=$(sh "$SCRIPT_DIR_SAVE/apt-install.sh" "$APT_MANIFEST" "$STORE_DIR/apt" 2>&1)
assert_contains "install: partial store -> loud fallback" "$out" "store missing deb(s) for:"
assert_contains "install: partial store -> network repair" "$(cat "$MOCK_LOG")" "apt-get update"

# wrong-arch store -> network tier, loud
rm -f "$STORE_DIR"/apt/*.deb
printf 'deb' >"$STORE_DIR/apt/liba_1.0-1_arm64.deb"
printf 'deb' >"$STORE_DIR/apt/libb_1.0-1_arm64.deb"
printf 'deb' >"$STORE_DIR/apt/app_1.0-1_arm64.deb"
printf 'deb' >"$STORE_DIR/apt/alt1_1.0-1_arm64.deb"
out=$(sh "$SCRIPT_DIR_SAVE/apt-install.sh" "$APT_MANIFEST" "$STORE_DIR/apt" 2>&1)
assert_contains "install: wrong-arch store -> loud fallback" "$out" "store arch arm64 != build arch amd64"
assert_contains "install: wrong-arch -> network repair" "$(cat "$MOCK_LOG")" "apt-get update"

# dpkg failure -> loud repair over the network
mv "$STORE_DIR/apt/liba_1.0-1_arm64.deb" "$_tmp.deb" 2>/dev/null || true
rm -f "$STORE_DIR"/apt/*.deb
# rebuild the amd64 store exactly as the populate fetch leaves it
for n in liba alt1 libb app; do printf 'deb' >"$STORE_DIR/apt/${n}_1.0-1_amd64.deb"; done
grep -v '^#' "$STORE_DIR/apt/install-order.txt" >/dev/null 2>&1 || printf 'liba_1.0-1_amd64.deb\nalt1_1.0-1_amd64.deb\nlibb_1.0-1_amd64.deb\napp_1.0-1_amd64.deb\n' >"$STORE_DIR/apt/install-order.txt"
: >"$MOCK_LOG"
MOCK_DPKG_RC=100 sh "$SCRIPT_DIR_SAVE/apt-install.sh" "$APT_MANIFEST" "$STORE_DIR/apt" >"$WORK/dpkgfail.out" 2>&1
rc=$?
assert "install: dpkg failure still exits 0 via repair" "$rc" "0"
assert_contains "install: dpkg failure -> loud repair log" "$(cat "$WORK/dpkgfail.out")" "repairing over the network tier"
case "$(cat "$MOCK_LOG")" in *"dpkg -i"*"apt-get update"*) pass "install: repair runs after failed dpkg" ;; *) fail "install: repair runs after failed dpkg" ;; esac

# missing order file -> alphabetical fallback (single dpkg transaction)
rm -f "$STORE_DIR/apt/install-order.txt"
: >"$MOCK_LOG"
out=$(sh "$SCRIPT_DIR_SAVE/apt-install.sh" "$APT_MANIFEST" "$STORE_DIR/apt" 2>&1)
assert_contains "install: legacy store -> alphabetical fallback WARN" "$out" "alphabetical fallback"
dpkg_line=$(grep '^dpkg -i ' "$MOCK_LOG" | tail -n 1)
assert "install: alphabetical dpkg args" "$dpkg_line" "dpkg -i $STORE_DIR/apt/alt1_1.0-1_amd64.deb $STORE_DIR/apt/app_1.0-1_amd64.deb $STORE_DIR/apt/liba_1.0-1_amd64.deb $STORE_DIR/apt/libb_1.0-1_amd64.deb"

# --- summary -------------------------------------------------------------------
echo ""
echo "==> test-apt-offline: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
