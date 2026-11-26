#!/usr/bin/env bash
# T8-context-provenance.sh — context records must carry verifiable provenance.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$SCRIPT_DIR/../context-provenance.sh"
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
export PROVENANCE_LOG="$D/prov.jsonl"
printf 'source text\n' > "$D/src.md"
pass=0; fail=0
check() {
  local label="$1" expr="$2" want="$3" got
  got=$(bash "$S" report 2>/dev/null | jq -r "$expr")
  if [[ "$got" == "$want" ]]; then pass=$((pass+1));
  else fail=$((fail+1)); echo "FAIL $label: $expr expected $want, got $got"; fi
}
check "empty" ".records" "0"
bash "$S" record --source "$D/src.md" --status verified --tool ctx_read >/dev/null || { fail=$((fail+1)); echo "FAIL record"; }
bash "$S" validate --source "$D/src.md" >/dev/null 2>&1 && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL validate verified"; }
check "records" ".records" "1"
check "verified" ".verified" "1"
check "by tool" '.by_tool.ctx_read' "1"
if bash "$S" validate --source "$D/none.md" >/dev/null 2>&1; then fail=$((fail+1)); echo "FAIL validate missing"; else pass=$((pass+1)); fi
if bash "$S" record --source "$D/src.md" --status bogus >/dev/null 2>&1; then fail=$((fail+1)); echo "FAIL invalid status"; else pass=$((pass+1)); fi
if bash "$S" record --source "$D/none.md" --status verified >/dev/null 2>&1; then fail=$((fail+1)); echo "FAIL missing source"; else pass=$((pass+1)); fi
bash "$S" record --source "$D/src.md" --status observed-once --tool rag >/dev/null
printf '%s\n' '{"source":"/no/such/file.md","evidence_status":"verified","tool":"rag"}' '{bad json' >> "$PROVENANCE_LOG"
check "malformed ignored" ".records" "3"
check "stale source" '.stale_sources[0]' "/no/such/file.md"
check "by status" '.by_status.verified' "2"
echo "T8 context provenance: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
