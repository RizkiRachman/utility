#!/usr/bin/env bash
# T12-shell-policy.sh — shell writes to policy artifacts are denied, not just audited.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$SCRIPT_DIR/../.." && pwd)"
C="$ENGINE/scripts/workflow-controller.sh"
G="$ENGINE/plugins/opencode-workflow-guard/guard.js"
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
mkdir -p "$D/session"
cp "$ENGINE/contract/contract.template.json" "$D/contract.json"
cp "$ENGINE/rules/rules.json" "$D/rules.json"
export CONTRACT_FILE="$D/contract.json" AUDIT_FILE="$D/audit.jsonl" RULES_FILE="$D/rules.json"
pass=0; fail=0
expect() {
  local want="$1" label="$2" cmd="$3"
  if bash "$C" pre_shell --command "$cmd" >/dev/null 2>&1; then got=allow; else got=deny; fi
  [[ "$got" == "$want" ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $label: expected $want, got $got"; }
}
if bash "$C" pre_shell >/dev/null 2>&1; then fail=$((fail+1)); echo "FAIL missing command"; else pass=$((pass+1)); fi
expect allow "ordinary write"        "echo hi > README.md"
expect allow "ordinary sed"          "sed -i 's/a/b/' README.md"
expect allow "contract read"         "cat session/contract.json"
expect deny  "contract write"        "cat x.md > session/contract.json"
expect deny  "env append"            "echo k=v >> .env"
expect deny  "opencode overwrite"    "cp a opencode.json"
expect deny  "session write"         "rm -rf .session/x"
expect deny  "audit overwrite"       "jq . x > session/workflow-audit.jsonl"
expect deny  "tool audit overwrite"  "tee session/tool-audit.jsonl < x"
expect deny  "ledger overwrite"      "tee session/scores.jsonl < x"
expect deny  "loop state overwrite"  "jq . session/loop-state.json > loop-state.json"
expect deny  "chmod contract"        "chmod 644 session/contract.json"
jq '.enforcement.shell_policy.protected_patterns += ["special.guard"]' "$D/rules.json" > "$D/r.new" && mv "$D/r.new" "$D/rules.json"
expect deny  "custom pattern"        "echo hi > special.guard"
[[ "$(jq -r 'select(.op=="pre_shell") | .status' "$D/audit.jsonl" | sort -u | tr '\n' ' ')" == "allow deny " ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL audit events"; }
grep -q 'pre_shell' "$G" && grep -q 'post_shell' "$G" && grep -q 'fallbackShellWrite' "$G" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL plugin routing"; }
echo "T12 shell policy: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
