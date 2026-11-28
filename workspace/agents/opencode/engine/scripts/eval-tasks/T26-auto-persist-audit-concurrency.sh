#!/usr/bin/env bash
# T26-auto-persist-audit-concurrency.sh — audit detection and writes are serialized.
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
jq '.state = "PLAN"' "$TARGET" > "$D/initial.json" && mv "$D/initial.json" "$TARGET"
cat > "$D/engine/scripts/snapshot-contract.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$D/bin/lean-ctx" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == knowledge && "$2" == --help ]]; then
  exit 0
fi
if [[ "$1" == knowledge && "$2" == recall ]]; then
  if ! mkdir "$RECALL_LOCK" 2>/dev/null; then
    : > "$RECALL_OVERLAP"
  fi
  sleep 0.15
  rmdir "$RECALL_LOCK" 2>/dev/null || true
  printf '{"state":"INIT"}\n'
  exit 0
fi
exit 0
EOF
chmod +x "$D/engine/scripts/snapshot-contract.sh" "$D/bin/lean-ctx"
export RECALL_LOCK="$D/recall.lockdir"
export RECALL_OVERLAP="$D/recall-overlap"
pass=0
fail=0

PATH="$D/bin:$PATH" bash "$D/engine/scripts/auto-persist.sh" --no-knowledge --file "$TARGET" >"$D/first.log" 2>&1 &
first_pid=$!
for _ in {1..100}; do
  [[ -d "$RECALL_LOCK" ]] && break
  sleep 0.01
done
if [[ ! -d "$RECALL_LOCK" ]]; then
  fail=$((fail+1)); echo "FAIL first persistence did not reach knowledge recall"
fi
PATH="$D/bin:$PATH" bash "$D/engine/scripts/auto-persist.sh" --no-knowledge --file "$TARGET" >"$D/second.log" 2>&1 &
second_pid=$!

if wait "$first_pid"; then
  pass=$((pass+1))
else
  fail=$((fail+1)); echo "FAIL first persistence failed"; cat "$D/first.log"
fi
if wait "$second_pid"; then
  pass=$((pass+1))
else
  fail=$((fail+1)); echo "FAIL second persistence failed"; cat "$D/second.log"
fi

if [[ ! -e "$RECALL_OVERLAP" ]]; then
  pass=$((pass+1))
else
  fail=$((fail+1)); echo "FAIL concurrent audit-state reads overlapped"
fi
if jq -e '.audit_log | length == 1' "$TARGET" >/dev/null 2>&1; then
  pass=$((pass+1))
else
  fail=$((fail+1)); echo "FAIL concurrent persistence did not leave exactly one audit event"
fi
if [[ ! -e "$TARGET.lockdir" ]]; then
  pass=$((pass+1))
else
  fail=$((fail+1)); echo "FAIL contract lock remained after concurrent persistence"
fi
shopt -s nullglob
staged_files=("$TARGET".tmp.*)
if [[ "${#staged_files[@]}" -eq 0 ]]; then
  pass=$((pass+1))
else
  fail=$((fail+1)); echo "FAIL audit or contract staging file leaked"
fi

echo "T26 auto-persist audit concurrency: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
