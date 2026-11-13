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
# populate-preinstall.sh calls this on a fresh host (certs/ empty), then trusts
# whatever landed there. certs/ stays gitignored - it now self-seeds.
#
# Usage: sh detect-zscaler.sh [output-dir] [probe-host]
#   output-dir  default: <script-dir>/certs   (created if missing)
#   probe-host  default: github.com
#
# Exit 0 = interception found, cert(s) written (or already present)
# Exit 1 = no interception detected (direct, clean chain)
# Exit 2 = environment/probe failure (openssl missing, no route to 443)
#
# Extraction is exposed as extract_zscaler_certs() for direct unit testing:
#   ZSHARED=1 . ./detect-zscaler.sh      # source without running main
set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

warn() { echo "WARN: $*" >&2; }
err()  { echo "ERROR: $*" >&2; }

# Extract certs mentioning Zscaler from a raw `s_client -showcerts` dump.
#
#   extract_zscaler_certs CHAIN_FILE OUT_DIR
#
# Prints each written file; returns 0 when at least one cert was written
# (or already existed by fingerprint), 1 when nothing matched.
extract_zscaler_certs() {
  _chain_file=$1
  _out_dir=$2
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

      # Fingerprint dedupe: an identical cert already in OUT_DIR is reused, not
      # rewritten. Keeps re-runs (and duplicate PEMs on the wire) idempotent.
      _fp=$(openssl x509 -noout -fingerprint -sha256 -in "$_cand" 2>/dev/null) || continue
      [ -n "$_fp" ] || continue
      _dup=0
      for _existing in "$_out_dir"/*.crt; do
        [ -f "$_existing" ] || continue
        _efp=$(openssl x509 -noout -fingerprint -sha256 -in "$_existing" 2>/dev/null) || continue
        if [ "$_efp" = "$_fp" ]; then
          _dup=1
          break
        fi
      done
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

main() {
  out_dir=${1:-$SCRIPT_DIR/certs}
  probe_host_default=${2:-github.com}

  # Already seeded? Nothing to detect - the existing CA trust takes over.
  for _crt in "$out_dir"/*.crt; do
    if [ -e "$_crt" ]; then
      echo "root CAs already present in $out_dir - skipping detection"
      return 0
    fi
  done

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
    return 2
  fi

  if ! tr 'A-Z' 'a-z' < "$_chain" | grep -q zscaler; then
    echo "no TLS interception detected (direct chain to $_probed)"
    rm -rf "$_tmpdir"
    return 1
  fi

  echo "==> TLS interception detected via $_probed (zscaler in chain)"
  extract_zscaler_certs "$_chain" "$out_dir"
  _rc=$?
  rm -rf "$_tmpdir"

  if [ "$_rc" -ne 0 ]; then
    warn "interception detected but no zscaler cert could be extracted from the chain"
    return 2
  fi

  echo "saved: $out_dir/zscaler-autodetected-*.crt - populate-preinstall.sh will trust these"
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