#!/usr/bin/env bash
# loop-validate.sh — deterministic in-loop validation gate (the "loop layer").
# Mirrors CI (validate.yml) so agents run the same cheap gates BEFORE declaring
# a change done, not only after push. Exit 0 = all gates pass; 1 = failure(s).
#
# Usage: bash scripts/loop-validate.sh [--full] [--tests '<cmd>']
#   --full       also run doc-style + conventions gates
#   --tests CMD  additionally run CMD from the project root (e.g. --tests 'mvn -q test')

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$SCRIPT_DIR/.." && pwd)"
PARENT="$(cd "$ENGINE/.." && pwd)"

# Dual layout: repo checkout (agents/opencode/{engine,config}) or deployed /opt/engine
if [ -f "$PARENT/entrypoint.sh" ] && [ -d "$PARENT/config" ]; then
  MODE="repo"; ROOT="$PARENT"
else
  MODE="deployed"; ROOT="$ENGINE"
fi

LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT
fail=0

echo "== loop-validate [$MODE] $ROOT"

# Gate 1 - JSON validity (parse-only; files may contain placeholder secrets)
jsonfail=0
check_json() { jq -e . "$1" >/dev/null 2>&1 || { echo "FAIL  json:$(basename "$1")"; jsonfail=1; }; }
if [ -d "$ENGINE/contract" ]; then
  while IFS= read -r -d '' f; do check_json "$f"; done < <(find "$ENGINE/contract" -maxdepth 1 -name '*.json' -print0 2>/dev/null)
fi
for f in "$ENGINE/rules/rules.json" "$ENGINE/rules/rules.schema.json" "$ENGINE/opencode.json.template"; do
  [ -f "$f" ] && check_json "$f"
done
if [ "$MODE" = "repo" ]; then
  [ -f "$ROOT/config/opencode.json" ] && check_json "$ROOT/config/opencode.json"
fi
[ "$jsonfail" -eq 0 ] && echo "PASS  json-validity" || fail=1

# Gate 2 - bash syntax sweep
bashfail=0
while IFS= read -r -d '' f; do
  bash -n "$f" 2>>"$LOG" || { echo "FAIL  bash-n:${f#$ROOT/}"; bashfail=1; }
done < <(find "$ENGINE/scripts" -maxdepth 1 -name '*.sh' -print0 2>/dev/null; printf '%s\0' "$ENGINE/setup.sh")
if [ "$MODE" = "repo" ]; then
  bash -n "$ROOT/entrypoint.sh" 2>>"$LOG" || { echo "FAIL  bash-n:entrypoint.sh"; bashfail=1; }
fi
[ "$bashfail" -eq 0 ] && echo "PASS  bash-syntax" || fail=1

# Gate 3 - cross-reference integrity (repo layout only; engine self-resolves)
if [ "$MODE" = "repo" ] && [ -f "$ENGINE/scripts/check-cross-references.sh" ]; then
  ( cd "$ROOT" && bash "$ENGINE/scripts/check-cross-references.sh" ) >"$LOG" 2>&1 \
    && echo "PASS  cross-references" || { echo "FAIL  cross-references"; tail -n 3 "$LOG" | sed 's/^/      | /'; fail=1; }
else
  echo "SKIP  cross-references (deployed layout)"
fi

# Optional gates
full=0; tests=""
while [ $# -gt 0 ]; do
  case "$1" in
    --full) full=1 ;;
    --tests) shift; tests="${1:-}" ;;
    *) echo "WARN  unknown arg: $1" ;;
  esac
  shift
done

if [ "$full" -eq 1 ]; then
  for s in check-doc-style.sh check-conventions.sh; do
    [ -f "$ENGINE/scripts/$s" ] || continue
    ( cd "$ROOT" && bash "$ENGINE/scripts/$s" ) >"$LOG" 2>&1 \
      && echo "PASS  $s" || { echo "FAIL  $s"; tail -n 3 "$LOG" | sed 's/^/      | /'; fail=1; }
  done
fi

if [ -n "$tests" ]; then
  ( cd "$ROOT" && eval "$tests" ) >"$LOG" 2>&1 \
    && echo "PASS  tests:$tests" || { echo "FAIL  tests:$tests"; tail -n 3 "$LOG" | sed 's/^/      | /'; fail=1; }
fi

echo "== loop-validate: $([ "$fail" -eq 0 ] && echo ALL-PASS || echo FAILED)"
exit "$fail"
