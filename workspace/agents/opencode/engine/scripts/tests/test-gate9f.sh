#!/usr/bin/env bash
# test-gate9f.sh - regression test for gate 9f (mangled-markdown detector).
# A char-per-line markdown file must fail --check forbidden-patterns with the
# "one-char letter flood" message; a clean control must pass.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CHECKER="$ENGINE_DIR/scripts/check-cross-references.sh"
WORK_DIR="${TMPDIR:-/tmp}/opencode/gate9f-tests"
PASS=0; FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
assert() { if [[ "$2" == "true" ]]; then pass "$1"; else fail "$1"; fi; }

[[ -f "$CHECKER" ]] || { echo "FATAL: missing $CHECKER" >&2; exit 1; }

# Engine-shaped root: the checker derives PROJECT_ROOT from its own location.
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/engine/scripts" "$WORK_DIR/engine/doc" "$WORK_DIR/engine/skills" "$WORK_DIR/engine/agents" "$WORK_DIR/engine/commands"
cp "$CHECKER" "$WORK_DIR/engine/scripts/"
TARGET="$WORK_DIR/engine/scripts/check-cross-references.sh"
FIXTURE="$WORK_DIR/engine/doc/mangled.md"

# Mangled fixture: >4 single-letter alpha lines (gate 9f threshold).
for c in a b c d e f g h i j k l; do printf '%s\n' "$c"; done > "$FIXTURE"
out="$(bash "$TARGET" --check forbidden-patterns 2>&1)"; rc=$?
assert "mangled markdown exits 1" "$([[ $rc -eq 1 ]] && echo true || echo false)"
assert "mangled markdown reports one-char letter flood" "$(printf '%s' "$out" | grep -q 'one-char letter flood' && echo true || echo false)"

# Clean control: no single-letter lines.
printf 'This is a clean document.\nEach line has several words in it.\nNothing here is mangled at all.\n' > "$FIXTURE"
out="$(bash "$TARGET" --check forbidden-patterns 2>&1)"; rc=$?
assert "clean markdown exits 0" "$([[ $rc -eq 0 ]] && echo true || echo false)"
assert "clean markdown has no flood warning" "$(printf '%s' "$out" | grep -q 'one-char letter flood' && echo false || echo true)"

rm -rf "$WORK_DIR"
echo "=== gate9f tests: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
