#!/usr/bin/env bash
# T21-contract-persistence.sh — persistence locks follow the selected contract.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$SCRIPT_DIR/../.." && pwd)"
PERSIST="$ENGINE/scripts/persist-contract.sh"
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
mkdir -p "$D/session" "$D/custom"
cp "$ENGINE/contract/contract.template.json" "$D/source.json"
export OPENCODE_PROJECT_ROOT="$D"
pass=0
fail=0

if bash "$PERSIST" --file "$D/custom/contract.json" --from-file "$D/source.json" >/dev/null 2>&1; then
  [[ -f "$D/custom/contract.json.lock" && ! -e "$D/session/contract.json.lock" ]] \
    && pass=$((pass+1)) \
    || { fail=$((fail+1)); echo "FAIL custom contract did not use its own lock path"; }
else
  fail=$((fail+1)); echo "FAIL custom contract persistence failed"
fi

if bash "$PERSIST" --from-file "$D/source.json" >/dev/null 2>&1; then
  [[ -f "$D/session/contract.json.lock" ]] \
    && pass=$((pass+1)) \
    || { fail=$((fail+1)); echo "FAIL default contract lock was not created"; }
else
  fail=$((fail+1)); echo "FAIL default contract persistence failed"
fi

if bash "$PERSIST" --file "$D/custom/contract.json" --from-file "$D/source.json" --validate >/dev/null 2>&1; then
  pass=$((pass+1))
else
  fail=$((fail+1)); echo "FAIL valid staged contract failed validation"
fi

REAL_MKTEMP=$(command -v mktemp)
mkdir -p "$D/bin"
cat > "$D/bin/mktemp" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "\$MKTEMP_LOG"
exec "$REAL_MKTEMP" "\$@"
EOF
chmod +x "$D/bin/mktemp"
export MKTEMP_LOG="$D/mktemp-args"
export PATH="$D/bin:$PATH"
: > "$MKTEMP_LOG"
if bash "$PERSIST" --file "$D/custom/contract.json" >/dev/null 2>&1; then
  grep -Fq "$D/custom/contract.json.tmp.XXXXXX" "$MKTEMP_LOG" \
    && pass=$((pass+1)) \
    || { fail=$((fail+1)); echo "FAIL staging file was not created beside target"; }
else
  fail=$((fail+1)); echo "FAIL same-directory staging persistence failed"
fi

printf '{"invalid":"schema"}\n' > "$D/invalid.json"
if SCHEMA_FILE="$D/missing-schema.json" bash "$PERSIST" --file "$D/custom/contract.json" --from-file "$D/invalid.json" --validate >/dev/null 2>&1; then
  fail=$((fail+1)); echo "FAIL invalid staged contract passed validation"
elif cmp -s "$D/custom/contract.json" "$D/source.json"; then
  pass=$((pass+1))
else
  fail=$((fail+1)); echo "FAIL validation failure changed the existing target"
fi

echo "T21 contract persistence: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
