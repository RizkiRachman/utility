#!/usr/bin/env bash
# T24-auto-persist-atomic.sh — auto-persist stages beside the target and rolls back failures.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$SCRIPT_DIR/../.." && pwd)"
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
TARGET="$D/custom/contract.json"
mkdir -p "$D/bin" "$D/engine/scripts/lib" "$D/engine/session" "$D/custom"
cp "$ENGINE/scripts/auto-persist.sh" "$D/engine/scripts/auto-persist.sh"
cp "$ENGINE/scripts/lib/common.sh" "$D/engine/scripts/lib/common.sh"
cp "$ENGINE/scripts/lib/knowledge.sh" "$D/engine/scripts/lib/knowledge.sh"
cp "$ENGINE/contract/contract.template.json" "$TARGET"
cp "$TARGET" "$D/original.json"
cat > "$D/engine/scripts/snapshot-contract.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$D/engine/scripts/snapshot-contract.sh"

REAL_MKTEMP=$(command -v mktemp)
REAL_JQ=$(command -v jq)
cat > "$D/bin/mktemp" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$D/mktemp-args"
exec "$REAL_MKTEMP" "\$@"
EOF
cat > "$D/bin/jq" <<EOF
#!/usr/bin/env bash
if [[ "\${FAIL_FORMAT:-false}" == true && "\$#" -eq 1 && "\$1" == "." ]]; then
  exit 42
fi
exec "$REAL_JQ" "\$@"
EOF
cat > "$D/bin/lean-ctx" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$D/bin/mktemp" "$D/bin/jq" "$D/bin/lean-ctx"
pass=0
fail=0

if output=$(PATH="$D/bin:$PATH" bash "$D/engine/scripts/auto-persist.sh" --no-knowledge --file "$TARGET" 2>&1); then
  if grep -Fq "$TARGET.tmp.XXXXXX" "$D/mktemp-args" \
    && jq -e . "$TARGET" >/dev/null \
    && [[ ! -e "$TARGET.lockdir" ]]; then
    pass=$((pass+1))
  else
    fail=$((fail+1)); echo "FAIL successful write did not stage beside target and release lock"
  fi
else
  fail=$((fail+1)); echo "FAIL auto-persist rejected valid contract: $output"
fi

cp "$TARGET" "$D/before-failure.json"
if output=$(FAIL_FORMAT=true PATH="$D/bin:$PATH" bash "$D/engine/scripts/auto-persist.sh" --no-knowledge --file "$TARGET" 2>&1); then
  fail=$((fail+1)); echo "FAIL staging formatter error was ignored"
elif [[ "$output" == *"Failed to write temp file"* ]] \
  && cmp -s "$D/before-failure.json" "$TARGET" \
  && [[ ! -e "$TARGET.lockdir" ]]; then
  pass=$((pass+1))
else
  fail=$((fail+1)); echo "FAIL failed staging changed the target or leaked the lock: $output"
fi

shopt -s nullglob
staged_files=("$TARGET".tmp.*)
if [[ "${#staged_files[@]}" -eq 0 ]]; then
  pass=$((pass+1))
else
  fail=$((fail+1)); echo "FAIL staging files were not cleaned up"
fi

echo "T24 auto-persist atomic staging: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
