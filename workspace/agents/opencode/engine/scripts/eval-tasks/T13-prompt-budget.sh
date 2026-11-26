#!/usr/bin/env bash
# T13-prompt-budget.sh — duplicate instruction text is measured and gated.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$SCRIPT_DIR/../prompt-budget.sh"
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
pass=0; fail=0
ok() { [[ "$2" == "$3" ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $1: expected $3, got $2"; }; }
report() { bash "$S" "$D" 2>/dev/null; }
field() { report | jq -r ".$1"; }
PTR='**Shared protocol**: read `engine/shared/protocol.md` at session start.'

for i in 1 2 3 4 5; do
  printf '# A%s\n%s\n%s\n' "$i" "$PTR" \
    'All tool access goes through lean-ctx for reads, discovery, shell commands, impact analysis, knowledge persistence, session saves, and post-flight verification before any commit or deployment.' > "$D/dup$i.md"
done
ok "duplicated status" "$(field status)" "over_budget"
if report >/dev/null; then fail=$((fail+1)); echo "FAIL duplicate should exit 1"; else pass=$((pass+1)); fi

rm -f "$D"/*.md
LONG='its phase-specific checks, escalation path, and completion evidence differ from every other agent in the scrum team and from the shared protocol it references'
for i in 1 2 3; do
  printf '# B%s\n%s\nAgent %s owns a unique responsibility with distinct tooling and gates; %s number %s.\n' "$i" "$PTR" "$i" "$LONG" "$i" > "$D/unique$i.md"
done
ok "unique status" "$(field status)" "within_budget"
if report >/dev/null; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL unique should exit 0"; fi

printf '# C1\nNo shared protocol reference in this agent instruction file at all.\n' > "$D/noptr.md"
ok "missing pointer" "$(field status)" "missing_shared_protocol"
rm -f "$D/noptr.md"

real=$(bash "$S" 2>/dev/null | jq -c '{status,duplication_pct,agents_without_pointer}')
ok "real corpus" "$(printf '%s' "$real" | jq -r .status)" "within_budget"
ok "real pointers" "$(printf '%s' "$real" | jq -r .agents_without_pointer)" "0"
echo "T13 prompt budget: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
