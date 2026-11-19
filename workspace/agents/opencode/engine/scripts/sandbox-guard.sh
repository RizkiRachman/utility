#!/usr/bin/env bash
# sandbox-guard.sh - sandbox pre-flight and session isolation enforcement.
#
# Enforces rules.json -> enforcement.sandbox:
#   preflight: before any scratch write, detect whether the cwd is already
#     inside a sandbox; on ambiguity, treat it as already inside; nested
#     sandbox creation is forbidden.
#   session_folder_first: create <sandbox-root>/<session-slug> before any
#     other scratch write.
#   cross_session_isolation: the folders of other sessions are invisible.
#
# Usage:
#   sandbox-guard.sh check                      verdict for the cwd
#   sandbox-guard.sh session <slug>             resolve and create the session folder; prints its path
#   sandbox-guard.sh isolation <slug> <path>    exit 1 when path is outside the own session folder
#   sandbox-guard.sh self-test                  built-in functional tests

set -u

is_marker_dir() { [ -f "$1/README.md" ] || [ -f "$1/.gitignore" ]; }

find_sandbox_root() {
  local d="$PWD"
  while :; do
    if [ "$(basename "$d")" = "sandbox" ] && is_marker_dir "$d"; then
      printf "%s\n" "$d"
      return 0
    fi
    [ "$d" = "/" ] && return 1
    d="$(dirname "$d")"
  done
}

find_repo_root() {
  local d="$PWD"
  while :; do
    [ -e "$d/.git" ] && { printf "%s\n" "$d"; return 0; }
    [ "$d" = "/" ] && return 1
    d="$(dirname "$d")"
  done
}

has_stacked_pair() {
  case "$1" in
    */sandbox/sandbox|*/sandbox/sandbox/*|sandbox/sandbox/*) return 0 ;;
    *) return 1 ;;
  esac
}

valid_slug() {
  printf "%s" "$1" | grep -qE "^[a-z0-9-]{1,40}$" || return 1
  case "$1" in
    -*|*-) return 1 ;;
  esac
  return 0
}

cmd_check() {
  if has_stacked_pair "$PWD"; then
    echo "FAIL: stacked double-sandbox path detected: $PWD"
    exit 2
  fi
  local root
  if root="$(find_sandbox_root)"; then
    echo "IN_SANDBOX: $root"
    echo "action: put the session folder directly under this root; never create another sandbox level"
    return 0
  fi
  if root="$(find_repo_root)"; then
    echo "OUT_SANDBOX: repo root $root"
    echo "action: session folder goes to $root/sandbox/<session-slug>"
    return 0
  fi
  echo "UNKNOWN: no sandbox marker and no repo root above $PWD"
  echo "action: assume you are already inside a sandbox; create nothing; navigate to a known project root"
  exit 3
}

cmd_session() {
  local slug="${1:-}" root target
  [ -n "$slug" ] || { echo "usage: sandbox-guard.sh session <slug>" >&2; exit 64; }
  valid_slug "$slug" || { echo "FAIL: invalid slug: $slug (lowercase a-z0-9 and hyphen, max 40, no leading or trailing hyphen)" >&2; exit 65; }
  if has_stacked_pair "$PWD"; then
    echo "FAIL: stacked double-sandbox path: $PWD" >&2
    exit 2
  fi
  if root="$(find_sandbox_root)"; then
    target="$root/$slug"
  elif root="$(find_repo_root)"; then
    mkdir -p "$root/sandbox"
    target="$root/sandbox/$slug"
  else
    echo "FAIL: no sandbox or repo root above $PWD - preflight rule: assume already inside a sandbox, create nothing" >&2
    exit 3
  fi
  mkdir -p "$target"
  printf "%s\n" "$target"
}


cmd_isolation() {
  local slug="${1:-}" path="${2:-}" root target
  [ -n "$slug" ] && [ -n "$path" ] || { echo "usage: sandbox-guard.sh isolation <slug> <path>" >&2; exit 64; }
  if root="$(find_sandbox_root)"; then
    target="$root/$slug"
  elif root="$(find_repo_root)"; then
    target="$root/sandbox/$slug"
  else
    target="$slug"
  fi
  case "$path" in
    "$target"|"$target"/*) echo "OK: inside own session folder ($target)"; exit 0 ;;
    *) echo "FAIL: outside own session folder ($target) - the folders of other sessions are invisible" >&2; exit 1 ;;
  esac
}

cmd_selftest() {
  local t pass=0 fail=0 out
  t="$(mktemp -d)"
  mkdir -p "$t/repo/.git" "$t/repo/sandbox/other-session"
  : > "$t/repo/sandbox/.gitignore"
  cd "$t/repo/sandbox/other-session" || exit 9
  out="$(bash "$GUARD" session my-slug 2>&1)"
  [ "$out" = "$t/repo/sandbox/my-slug" ] && { pass=$((pass+1)); echo "PASS: in-sandbox session resolves under the existing root"; } || { fail=$((fail+1)); echo "FAIL: in-sandbox session resolved to: $out"; }
  [ -d "$t/repo/sandbox/sandbox" ] && { fail=$((fail+1)); echo "FAIL: a stacked sandbox level was created"; } || pass=$((pass+1))
  if bash "$GUARD" isolation my-slug "$t/repo/sandbox/other-session/x" >/dev/null 2>&1; then
    fail=$((fail+1)); echo "FAIL: a path in another session folder passed isolation"
  else
    pass=$((pass+1)); echo "PASS: path in another session folder rejected"
  fi
  if bash "$GUARD" isolation my-slug "$t/repo/sandbox/my-slug/x" >/dev/null 2>&1; then
    pass=$((pass+1)); echo "PASS: path inside own session folder accepted"
  else
    fail=$((fail+1)); echo "FAIL: path inside own session folder rejected"
  fi
  mkdir -p "$t/fresh/.git"
  cd "$t/fresh" || exit 9
  out="$(bash "$GUARD" session fresh-slug 2>&1)"
  [ "$out" = "$t/fresh/sandbox/fresh-slug" ] && { pass=$((pass+1)); echo "PASS: fresh repo creates sandbox/<slug>"; } || { fail=$((fail+1)); echo "FAIL: fresh repo session resolved to: $out"; }
  mkdir -p "$t/nowhere/deep"
  cd "$t/nowhere/deep" || exit 9
  if bash "$GUARD" session x >/dev/null 2>&1; then
    fail=$((fail+1)); echo "FAIL: unknown territory created something"
  else
    pass=$((pass+1)); echo "PASS: unknown territory refused (assume in-sandbox, create nothing)"
  fi
  cd "$t/repo" || exit 9
  if bash "$GUARD" session Bad_Slug >/dev/null 2>&1; then
    fail=$((fail+1)); echo "FAIL: invalid slug accepted"
  else
    pass=$((pass+1)); echo "PASS: invalid slug rejected"
  fi
  echo "self-test: $pass passed, $fail failed"
  rm -rf "$t"
  [ "$fail" -eq 0 ]
}

GUARD="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
case "${1:-check}" in
  check) cmd_check ;;
  session) shift; cmd_session "${1:-}" ;;
  isolation) shift; cmd_isolation "${1:-}" "${2:-}" ;;
  self-test) cmd_selftest ;;
  *) echo "usage: sandbox-guard.sh check | session <slug> | isolation <slug> <path> | self-test" >&2; exit 64 ;;
esac
