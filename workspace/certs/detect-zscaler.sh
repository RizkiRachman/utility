#!/bin/sh
if grep -q "$(printf '\r')" "$0" 2>/dev/null; then
  _lf="${TMPDIR:-/tmp}/.${0##*/}.$$.lf"
  tr -d '\r' < "$0" > "$_lf" && exec sh "$_lf" "$@"
fi # CRLF self-heal: re-exec an LF copy from TMPDIR when Windows line endings are detected

# Detect corporate TLS interception (Zscaler and friends) and seed certs/.
#
# Behind a TLS-inspecting proxy every HTTPS chain presents the proxy's OWN
# certificate instead of the real site CA - so the intercepting cert can be
# read straight off the wire. Zscaler names itself in the subject/issuer of
# every cert it presents:
#   - Root CA (self-signed, 27-year validity) -> preferred trust anchor
#   - Long-lived Intermediate CA (CA:TRUE, 27-year validity) -> fallback anchor
#     only when no self-signed Root CA is present
#   - Ephemeral "(t)" Intermediate CA (14-day validity) & per-site leaf certs
#     -> always skipped
#
# MULTI-HOST PROBE: zscaler presents DIFFERENT issuer chains per site, so
# DEFAULT_PROBE_HOSTS are probed in parallel on every run and merged into one
# fingerprint-deduped set.
#
# ROTATION-READY: every invocation re-probes the live wire and replaces the
# autodetected set rather than appending, preventing silent stale-cert failures.
#
# Cert ownership split:
#   zscaler-autodetected-*.crt  detector OUTPUT set - deleted and rewritten on
#                               every interception-found run.
#   any other *.crt             MANUAL certs (e.g. zscaler-root-ca.crt) - never
#                               touched, never pruned.
#
# Usage: sh detect-zscaler.sh [output-dir] [probe-host]
#   output-dir  default: script's own dir (created if missing)
#   probe-host  optional single-host override (probes ONLY that host)
#
# Exit 0 = interception found on at least one host, cert set refreshed
# Exit 1 = probes ran and none of the reachable hosts shows interception
#          (direct, clean chains; stale autodetected certs removed)
# Exit 2 = environment/probe failure - openssl missing, no host reachable on
#          443, or interception seen but nothing extractable (existing certs kept)
#
# Direct unit-test entry point:
#   ZSHARED=1 . ./detect-zscaler.sh
set -u

AUTODETECTED_PREFIX="zscaler-autodetected-"
DEFAULT_PROBE_HOSTS="github.com pypi.org download.pytorch.org download.eclipse.org"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

warn() { echo "WARN: $*" >&2; }
err()  { echo "ERROR: $*" >&2; }

# Extract valid Zscaler CA certs from a raw `s_client -showcerts` dump.
#
#   extract_zscaler_certs CHAIN_FILE OUT_DIR [SKIP_FP_FILE]
#
# Writes self-signed Zscaler Root CAs first, followed by long-lived (non-"(t)")
# CA:TRUE intermediates. Appends newly written SHA-256 fingerprints to
# SKIP_FP_FILE when provided so multi-host runs dedupe without re-hashing.
# Returns 0 if at least one matching cert was found/written, 1 otherwise.
extract_zscaler_certs() {
  _chain_file=$1
  _out_dir=$2
  _skip_fp_file=${3:-}
  _zfound=0

  _work=$(mktemp -d) || return 1
  _pem="$_work/chain.pem"
  sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' \
    "$_chain_file" > "$_pem" 2>/dev/null || true
  if [ ! -s "$_pem" ]; then
    rm -rf "$_work"
    return 1
  fi

  # Split PEM blocks portably (no csplit dependency)
  awk -v dir="$_work" '
    /-----BEGIN CERTIFICATE-----/ { n++ }
    n > 0 { print > (dir "/raw-" sprintf("%03d", n) ".pem") }
  ' "$_pem"

  mkdir -p "$_work/0_root" "$_work/1_interm"
  _idx=0

  # Single-pass metadata extraction per cert (1 openssl call per cert total)
  for _cand in "$_work"/raw-*.pem; do
    [ -f "$_cand" ] || continue
    _meta=$(openssl x509 -noout -subject -issuer -fingerprint -sha256 \
      -ext basicConstraints -in "$_cand" 2>/dev/null) || continue

    _subj=$(printf '%s\n' "$_meta" | sed -n 's/^subject=//p' | tr 'A-Z' 'a-z')
    _iss=$(printf '%s\n' "$_meta" | sed -n 's/^issuer=//p' | tr 'A-Z' 'a-z')
    case "$_subj$_iss" in
      *zscaler*) ;;
      *) continue ;;
    esac

    _fp=$(printf '%s\n' "$_meta" | sed -n 's/^sha256 Fingerprint=//p')
    [ -n "$_fp" ] || continue

    _idx=$((_idx + 1))
    _tag=$(printf '%03d' "$_idx")

    if [ "$_subj" = "$_iss" ]; then
      # Self-signed Zscaler Root CA
      printf '%s\n' "$_fp" > "$_work/0_root/$_tag.fp"
      cp "$_cand" "$_work/0_root/$_tag.pem"
    else
      # Extract Subject CN (handles both comma- and slash-delimited OpenSSL output)
      _cn=$(printf '%s\n' "$_subj" | sed 's/.*cn *= *//' | sed 's/[,/][a-z][a-z0-9.]* *=.*//' | tr -d '"')
      case "$_cn" in
        *zscaler*) ;;
        *) continue ;;
      esac
      # Skip ephemeral 14-day cloud signing CAs marked with "(t)"
      case "$_cn" in
        *"(t)"*) continue ;;
      esac
      # Must be a CA certificate (CA:TRUE), never a per-site or *.zscloud.net leaf
      printf '%s\n' "$_meta" | grep -q 'CA:TRUE' || continue

      printf '%s\n' "$_fp" > "$_work/1_interm/$_tag.fp"
      cp "$_cand" "$_work/1_interm/$_tag.pem"
    fi
  done

  # Pre-collect manual cert fingerprints once
  _manual_fps=""
  for _existing in "$_out_dir"/*.crt; do
    [ -f "$_existing" ] || continue
    case "${_existing##*/}" in
      "$AUTODETECTED_PREFIX"*) continue ;;
    esac
    _efp=$(openssl x509 -noout -fingerprint -sha256 -in "$_existing" 2>/dev/null) || continue
    [ -n "$_efp" ] && _manual_fps="${_manual_fps}${_efp}
"
  done

  # Write staged certs in strict priority order: 0_root first, then 1_interm
  for _stage in "$_work/0_root" "$_work/1_interm"; do
    for _cand in "$_stage"/*.pem; do
      [ -f "$_cand" ] || continue
      _fp_file="${_cand%.pem}.fp"
      _fp=$(cat "$_fp_file")
      _full_fp="sha256 Fingerprint=$_fp"

      _dup=0
      if [ -n "$_manual_fps" ] && printf '%s' "$_manual_fps" | grep -qxF "$_full_fp"; then
        _dup=1
      elif [ -n "$_skip_fp_file" ] && [ -s "$_skip_fp_file" ] && grep -qxF "$_full_fp" "$_skip_fp_file"; then
        _dup=1
      fi

      if [ "$_dup" -eq 1 ]; then
        _zfound=1
        continue
      fi

      _n=1
      while [ -e "$_out_dir/${AUTODETECTED_PREFIX}${_n}.crt" ]; do
        _n=$((_n + 1))
      done
      _dest="$_out_dir/${AUTODETECTED_PREFIX}${_n}.crt"
      if cp "$_cand" "$_dest" 2>/dev/null; then
        echo "saved: $_dest"
        _zfound=1
        [ -n "$_skip_fp_file" ] && printf '%s\n' "$_full_fp" >> "$_skip_fp_file"
      else
        warn "could not write $_dest"
      fi
    done
  done

  rm -rf "$_work"
  [ "$_zfound" -eq 1 ]
}

# Probe a single host with a bounded 15s timeout; returns 0 if non-empty chain captured.
probe_host() {
  _host=$1
  _dest=$2
  timeout 15 sh -c \
    "echo | openssl s_client -connect ${_host}:443 -servername ${_host} -showcerts" \
    > "$_dest" 2>/dev/null || true
  [ -s "$_dest" ]
}

# Delete this script's autodetected set; prints count removed.
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

# Find the first self-signed CA cert in $1; prints full path or nothing.
find_root_cert() {
  _dir=$1
  for _crt in "$_dir"/*.crt; do
    [ -f "$_crt" ] || continue
    _info=$(openssl x509 -noout -subject -issuer -in "$_crt" 2>/dev/null) || continue
    _subj=$(printf '%s\n' "$_info" | sed -n 's/^subject=//p' | tr 'A-Z' 'a-z')
    _iss=$(printf '%s\n' "$_info" | sed -n 's/^issuer=//p' | tr 'A-Z' 'a-z')
    if [ -n "$_subj" ] && [ "$_subj" = "$_iss" ]; then
      printf '%s' "$_crt"
      return 0
    fi
  done
  return 1
}

main() {
  out_dir=${1:-$SCRIPT_DIR}
  single_host=${2:-}

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

  if [ -n "$single_host" ]; then
    probe_hosts=$single_host
  else
    probe_hosts=$DEFAULT_PROBE_HOSTS
  fi

  _tmpdir=$(mktemp -d) || { err "mktemp failed"; return 2; }
  _chain_dir="$_tmpdir/chains"
  mkdir -p "$_chain_dir"

  # Probe all hosts in parallel to bound total latency to a single timeout window
  for _host in $probe_hosts; do
    probe_host "$_host" "$_chain_dir/$_host.txt" &
  done
  wait

  _probed=0
  _intercepted=0
  for _host in $probe_hosts; do
    _chain="$_chain_dir/$_host.txt"
    if [ -s "$_chain" ]; then
      _probed=$((_probed + 1))
      if tr 'A-Z' 'a-z' < "$_chain" | grep -q zscaler; then
        echo "==> TLS interception detected via $_host (zscaler in chain)"
        _intercepted=$((_intercepted + 1))
      else
        echo "no TLS interception detected (direct chain to $_host)"
        rm -f "$_chain"
      fi
    else
      rm -f "$_chain"
      warn "probe to $_host failed (no TLS handshake) - skipping this host"
    fi
  done

  if [ "$_probed" -eq 0 ]; then
    rm -rf "$_tmpdir"
    warn "no TLS handshake succeeded on any probe host ($probe_hosts) - cannot tell direct from intercepted"
    warn "leaving $out_dir untouched (existing certs kept)"
    return 2
  fi

  if [ "$_intercepted" -eq 0 ]; then
    _total=$(printf '%s\n' "$probe_hosts" | wc -w | tr -d ' ')
    echo "no TLS interception detected on any reachable host (probed $_probed of $_total)"
    rm -rf "$_tmpdir"
    _stale=$(clear_autodetected_certs "$out_dir")
    echo "no interception - removed $_stale stale autodetected cert(s)"
    return 1
  fi

  # Replace, never append: clear old autodetected set first; extract_zscaler_certs
  # automatically dedupes against surviving manual *.crt files and grows $_dedupe_fp.
  _dedupe_fp="$_tmpdir/dedupe-fingerprints.txt"
  : > "$_dedupe_fp"
  _old=$(clear_autodetected_certs "$out_dir")

  for _chain in "$_chain_dir"/*.txt; do
    [ -f "$_chain" ] || continue
    extract_zscaler_certs "$_chain" "$out_dir" "$_dedupe_fp" || true
  done
  rm -rf "$_tmpdir"

  # If a self-signed Root CA is present (wire-captured or manual zscaler-root-ca.crt),
  # prune any autodetected intermediate already signed by that Root CA so only the
  # clean Root CA trust anchor remains.
  _root_path=$(find_root_cert "$out_dir" || true)
  _pruned=0
  if [ -n "$_root_path" ]; then
    for _crt in "$out_dir/$AUTODETECTED_PREFIX"*.crt; do
      [ -f "$_crt" ] || continue
      [ "$_crt" = "$_root_path" ] && continue
      if openssl verify -CAfile "$_root_path" "$_crt" >/dev/null 2>&1; then
        rm -f "$_crt"
        _pruned=$((_pruned + 1))
      fi
    done
  fi

  _fresh=$(ls "$out_dir/$AUTODETECTED_PREFIX"*.crt 2>/dev/null | wc -l | tr -d ' ')
  if [ "$_fresh" -eq 0 ] && [ -z "$_root_path" ]; then
    warn "interception detected but no long-lived zscaler CA cert could be extracted from any chain"
    warn "the previous autodetected set was already removed - re-run or seed $out_dir/zscaler-root-ca.crt"
    return 2
  fi

  echo "refreshed: $_fresh autodetected cert(s) in $out_dir (merged from $_intercepted intercepted host(s), replaced $_old, pruned $_pruned redundant intermediate(s))"
  [ "$_fresh" -gt 0 ] && echo "saved: $out_dir/$AUTODETECTED_PREFIX*.crt - populate-preinstall.sh will trust these"

  if [ -n "$_root_path" ]; then
    _root_name=${_root_path##*/}
    case "$_root_name" in
      "$AUTODETECTED_PREFIX"*)
        echo "root captured on the wire: self-signed $_root_name (full-chain trust)" ;;
      *)
        echo "root present: manual self-signed $_root_name (full-chain trust; redundant intermediates pruned)" ;;
    esac
  else
    warn "no self-signed ROOT in the set - these intermediates anchor ONLY the probed hosts"
    warn "export the Zscaler Root CA from the portal and save it as $out_dir/zscaler-root-ca.crt (allowlisted; this script never touches it)"
  fi

  return 0
}

case "${ZSHARED:-}" in
  1) : ;;
  *)
    case "$0" in
      *detect-zscaler.sh) main "$@" ;;
      *) : ;;
    esac
    ;;
esac