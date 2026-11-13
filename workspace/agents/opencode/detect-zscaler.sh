#!/bin/sh
# Detect corporate TLS interception (Zscaler and friends) and seed certs/.
#
# Behind a TLS-inspecting proxy every HTTPS chain presents the proxy's OWN
# certificate instead of the real site CA - so the intercepting cert can be
# read straight off the wire, no manual copying required. Zscaler names itself
# in the subject/issuer of every cert it presents; the chain usually carries
# only its INTERMEDIATE (the root is rarely sent), and one trusted intermediate
# is a sufficient trust anchor for openssl/curl. All chain certs that mention
# Zscaler are saved.
#
# ROTATION-READY: the probe runs on EVERY invocation and the autodetected set
# is replaced, not appended to. Corporate MITM roots rotate (new intermediates,
# new pinning), so a once-captured cert goes stale silently; re-deriving it
# from the live wire each run keeps the store trusted. This is why
# populate-preinstall.sh calls the detector unconditionally: it is safe to run
# on a schedule.
#
# Cert ownership split (the whole refresh rule):
#   zscaler-autodetected-*.crt  the detector's OUTPUT set - deleted and
#                               rewritten on every interception-found run.
#   any other *.crt             MANUAL certs - never touched, never counted
#                               as "already handled", never pruned.
#
# populate-preinstall.sh calls this on every run, then trusts whatever landed
# in certs/. certs/ stays gitignored - it self-seeds and self-refreshes.
#
# Usage: sh detect-zscaler.sh [output-dir] [probe-host]
#   output-dir  default: <script-dir>/certs   (created if missing)
#   probe-host  default: github.com
#
# Exit 0 = interception found, autodetected cert set refreshed
# Exit 1 = no interception detected (direct, clean chain; stale autodetected
#          certs removed)
# Exit 2 = environment/probe failure (openssl missing, no route to 443) -
#          certs are left untouched because nothing could be verified
#
# Extraction is exposed as extract_zscaler_certs() for direct unit testing:
#   ZSHARED=1 . ./detect-zscaler.sh      # source without running main
set -u

# Prefix of the files this script owns. Anything else in out_dir is manual.
AUTODETECTED_PREFIX="zscaler-autodetected-"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

warn() { echo "WARN: $*" >&2; }
err()  { echo "ERROR: $*" >&2; }

# Extract certs mentioning Zscaler from a raw `s_client -showcerts` dump.
#
#   extract_zscaler_certs CHAIN_FILE OUT_DIR [SKIP_FP_FILE]
#
# Prints each written file; returns 0 when at least one cert was written, 1
# when nothing matched.
#
# Fingerprint dedupe compares only against files NOT owned by this script
# (manual certs), plus fingerprints listed in SKIP_FP_FILE (the surviving
# manual fingerprints, when the caller pre-collected them). The autodetected
# set is the caller's replace-target: a fresh run must rewrite it, so the old
# copies must never suppress a re-extraction.
extract_zscaler_certs() {
  _chain_file=$1
  _out_dir=$2
  _skip_fp_file=${3:-}
  _zfound=0

  _work=$(mktemp -d) || return 1
  # Always clean the scratch dir, including on early return.
  # (No traps: the function owns its scratch lifetime, main owns its own.)
  _pem="$_work/chain.pem"
  sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' \
    "$_chain_file" > "$_pem" 2>/dev/null || true
  if [ ! -s "$_pem" ]; then
    rm -rf "$_work"
    return 1
  fi

  # Split individual PEM blocks: csplit writes cert00, cert01, ... (suffix %02d).
  # -s silent, -z elide empty leading file, -k keep on error.
  ( cd "$_work" && csplit -szk -f cert "$_pem" \
      '/-----BEGIN CERTIFICATE-----/' '{*}' >/dev/null 2>&1 ) || true

  # Pass 1: self-signed-looking Zscaler certs (issuer == subject) - the closest
  # thing to a root the proxy sends. Pass 2: everything else that names Zscaler.
  for _pass in root other; do
    for _cand in "$_work"/cert*; do
      [ -f "$_cand" ] || continue
      _info=$(openssl x509 -noout -subject -issuer -in "$_cand" 2>/dev/null) || continue
      _subj=$(printf '%s\n' "$_info" | sed -n 's/^subject=//p' | tr 'A-Z' 'a-z')
      _iss=$(printf '%s\n' "$_info" | sed -n 's/^issuer=//p' | tr 'A-Z' 'a-z')
      case "$_subj$_iss" in
        *zscaler*) ;;
        *) continue ;;
      esac
      if [ "$_pass" = root ]; then
        [ "$_subj" = "$_iss" ] || continue
      else
        [ "$_subj" = "$_iss" ] && continue
      fi

      # Fingerprint dedupe: only the SURVIVING certs count - manual certs in
      # OUT_DIR (anything not named zscaler-autodetected-*) plus the caller's
      # pre-collected manual fingerprint list. The autodetected set is being
      # replaced, so it must not suppress the fresh extraction.
      _fp=$(openssl x509 -noout -fingerprint -sha256 -in "$_cand" 2>/dev/null) || continue
      [ -n "$_fp" ] || continue
      _dup=0
      for _existing in "$_out_dir"/*.crt; do
        [ -f "$_existing" ] || continue
        case "${_existing##*/}" in
          "$AUTODETECTED_PREFIX"*) continue ;;
        esac
        _efp=$(openssl x509 -noout -fingerprint -sha256 -in "$_existing" 2>/dev/null) || continue
        if [ "$_efp" = "$_fp" ]; then
          _dup=1
          break
        fi
      done
      if [ "$_dup" -eq 0 ] && [ -n "$_skip_fp_file" ] && [ -s "$_skip_fp_file" ]; then
        if grep -qxF "$_fp" "$_skip_fp_file"; then
          _dup=1
        fi
      fi
      if [ "$_dup" -eq 1 ]; then
        _zfound=1
        continue
      fi

      _n=1
      while [ -e "$_out_dir/zscaler-autodetected-$_n.crt" ]; do
        _n=$((_n + 1))
      done
      _dest="$_out_dir/zscaler-autodetected-$_n.crt"
      if cp "$_cand" "$_dest" 2>/dev/null; then
        echo "saved: $_dest"
        _zfound=1
      else
        warn "could not write $_dest"
      fi
    done
  done

  rm -rf "$_work"
  [ "$_zfound" -eq 1 ]
}

# Run one probe host; writes the raw chain to $1, returns 0 on a non-empty chain.
probe_host() {
  _host=$1
  _dest=$2
  timeout 10 sh -c \
    "echo | openssl s_client -connect ${_host}:443 -servername ${_host} -showcerts" \
    > "$_dest" 2>/dev/null || true
  [ -s "$_dest" ]
}

# Delete this script's autodetected set; prints how many files were removed.
# Manual certs (any *.crt not carrying AUTODETECTED_PREFIX) are never touched.
# $1 = out_dir, $2 = "verbose" to print each removal.
clear_autodetected_certs() {
  _dir=$1
  _verbose=${2:-}
  _removed=0
  for _crt in "$_dir/$AUTODETECTED_PREFIX"*.crt; do
    [ -f "$_crt" ] || continue
    if rm -f "$_crt"; then
      _removed=$((_removed + 1))
      [ -n "$_verbose" ] && echo "removed: $_crt"
    else
      warn "could not remove $_crt"
    fi
  done
  printf '%s' "$_removed"
}

main() {
  out_dir=${1:-$SCRIPT_DIR/certs}
  probe_host_default=${2:-github.com}

  # NO early exit on an existing cert set: autodetected certs go stale when the
  # corporate root rotates, so every run probes and refreshes its own set.

  # openssl is the whole tool; install it in a root preinstall container so the
  # call stays zero-config, and fail cleanly everywhere else.
  if ! command -v openssl >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
      apt-get install -y -qq openssl >/dev/null 2>&1 || true
    fi
    if ! command -v openssl >/dev/null 2>&1; then
      err "openssl not found - cannot probe for TLS interception"
      return 2
    fi
  fi

  mkdir -p "$out_dir" || { err "cannot create $out_dir"; return 2; }

  _tmpdir=$(mktemp -d) || { err "mktemp failed"; return 2; }
  _chain="$_tmpdir/chain.txt"

  # First reachable probe wins; a blocked github.com should not mask a working
  # google.com when the proxy only allowlists some hosts.
  _probed=
  for _host in "$probe_host_default" www.google.com; do
    if probe_host "$_host" "$_chain"; then
      _probed=$_host
      break
    fi
  done

  if [ -z "$_probed" ]; then
    rm -rf "$_tmpdir"
    warn "no TLS handshake succeeded (tried $probe_host_default, www.google.com) - cannot tell direct from intercepted"
    warn "leaving $out_dir untouched (existing certs kept)"
    return 2
  fi

  if ! tr 'A-Z' 'a-z' < "$_chain" | grep -q zscaler; then
    echo "no TLS interception detected (direct chain to $_probed)"
    rm -rf "$_tmpdir"
    _stale=$(clear_autodetected_certs "$out_dir")
    echo "no interception - removed $_stale stale autodetected cert(s)"
    return 1
  fi

  echo "==> TLS interception detected via $_probed (zscaler in chain)"

  # Manual fingerprints are collected BEFORE the autodetected set is cleared,
  # so a manual cert's fingerprint still suppresses a duplicate write. (The
  # extractor also rescans surviving manual certs; this list is belt-and-braces
  # for hosts where the rescan cannot re-read a file.)
  _manual_fp="$_tmpdir/manual-fingerprints.txt"
  : > "$_manual_fp"
  for _crt in "$out_dir"/*.crt; do
    [ -f "$_crt" ] || continue
    case "${_crt##*/}" in
      "$AUTODETECTED_PREFIX"*) continue ;;
    esac
    _f=$(openssl x509 -noout -fingerprint -sha256 -in "$_crt" 2>/dev/null) || continue
    [ -n "$_f" ] && printf '%s\n' "$_f" >> "$_manual_fp"
  done

  # Replace, never append: drop the old autodetected set first so a rotated
  # root does not leave the superseded cert trusted forever.
  _old=$(clear_autodetected_certs "$out_dir")
  extract_zscaler_certs "$_chain" "$out_dir" "$_manual_fp"
  _rc=$?
  rm -rf "$_tmpdir"

  if [ "$_rc" -ne 0 ]; then
    warn "interception detected but no zscaler cert could be extracted from the chain"
    warn "the previous autodetected set was already removed - re-run when the probe works"
    return 2
  fi

  _fresh=$(ls "$out_dir/$AUTODETECTED_PREFIX"*.crt 2>/dev/null | wc -l | tr -d ' ')
  echo "refreshed: $_fresh cert(s) in $out_dir (replaced $_old autodetected)"
  echo "saved: $out_dir/$AUTODETECTED_PREFIX*.crt - populate-preinstall.sh will trust these"
  return 0
}

# Sourced for unit tests -> expose functions only; run main only when this file
# is the entry script. Detecting "sourced" portably: $0 differs from the file.
# Unit tests set ZSHARED=1 explicitly; a plain `. ./detect-zscaler.sh` with
# ZSHARED unset also stays inert (source-safe default).
case "${ZSHARED:-}" in
  1) : ;;                      # explicitly sourced for tests
  *) 
    # $0 is the calling shell when sourced - if it is not this file, stay inert.
    case "$0" in
      *detect-zscaler.sh) main "$@" ;;
      *) : ;;
    esac
    ;;
esac