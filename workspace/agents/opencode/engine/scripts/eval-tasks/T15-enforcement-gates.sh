#!/usr/bin/env bash
# T15-enforcement-gates.sh — schema, phase evidence, and completion gates.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$SCRIPT_DIR/../.." && pwd)"
C="$ENGINE/scripts/workflow-controller.sh"
T="$ENGINE/scripts/transition.sh"
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
mkdir -p "$D/session"
cp "$ENGINE/contract/contract.template.json" "$D/contract.json"
cp "$ENGINE/rules/rules.json" "$D/rules.json"
printf '# S\n\n## Current Focus\n\nT\n\n## Known Blockers\n\nN\n' > "$D/state.md"
export CONTRACT_FILE="$D/contract.json" AUDIT_FILE="$D/audit.jsonl" RULES_FILE="$D/rules.json"
pass=0; fail=0
ok() { [[ "$2" == "$3" ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $1: expected $3, got $2"; }; }
allow() { bash "$C" "$@" >/dev/null 2>&1; }
trans() { bash "$T" --to "$1" --agent orchestrator --evidence "$2" >/dev/null 2>&1; }

# 1. A structurally incomplete contract with a valid state must be denied.
jq 'del(.scope) | .state="PLAN"' "$D/contract.json" > "$D/bad.json"
CONTRACT_FILE="$D/bad.json" bash "$C" pre_tool_action --tool edit --target "$D/README.md" >/dev/null 2>&1 && \
  { fail=$((fail+1)); echo "FAIL incomplete contract accepted"; } || pass=$((pass+1))

# 2. Scored edges require ledger evidence, not just a file.
trans PLAN "file:$D/state.md" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL INIT->PLAN"; }
trans PLAN_SCORED "file:$D/state.md" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL PLAN->PLAN_SCORED"; }
if trans EXECUTE "file:$D/state.md"; then fail=$((fail+1)); echo "FAIL scored edge accepted file"; else pass=$((pass+1)); fi
printf '%s\n' '{"phase":"PLAN_SCORED","verdict":"PASS","tier1_only":false}' > "$D/scores.jsonl"
trans EXECUTE "ledger:PASS" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL scored edge rejected ledger"; }

# 3. Leaving BLOCKED requires manual evidence and user override.
trans BLOCKED "file:$D/state.md" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL ->BLOCKED"; }
if trans INIT "file:$D/state.md"; then fail=$((fail+1)); echo "FAIL BLOCKED exit accepted file"; else pass=$((pass+1)); fi
jq '.governance.user_override=true' "$D/contract.json" > "$D/c.new" && mv "$D/c.new" "$D/contract.json"
trans INIT "manual:user reviewed SLA breach" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL BLOCKED exit rejected manual"; }

# 3b. Retry exhaustion, not only low score, makes BLOCKED escalation legal.
jq '.state="EXECUTE_SCORED" | .score.combined=60 | .retry.attempt=3 | .retry.max_attempts=3' "$D/contract.json" > "$D/exhausted.json"
if bash "$ENGINE/scripts/state-guard.sh" --agent orchestrator --contract "$D/exhausted.json" --to BLOCKED >/dev/null 2>&1; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL exhausted retries denied BLOCKED"; fi
jq '.retry.attempt=1' "$D/exhausted.json" > "$D/retries-left.json"
if bash "$ENGINE/scripts/state-guard.sh" --agent orchestrator --contract "$D/retries-left.json" --to BLOCKED >/dev/null 2>&1; then fail=$((fail+1)); echo "FAIL retry-left escalation accepted"; else pass=$((pass+1)); fi

# 4. Completion requires a ledger entry for every scored phase.
ok "no bootstrap" "$(bash "$C" pre_completion >/dev/null 2>&1; echo $?)" "1"
jq --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.governance.memory_bootstrap.at=$t | .governance.judge_coverage.judge_backed=1' "$D/contract.json" > "$D/c.new" && mv "$D/c.new" "$D/contract.json"
printf '%s\n' '{"phase":"REVIEW","verdict":"PASS","tier1_only":false}' '{bad json' >> "$D/scores.jsonl"
printf '%s\n' '{"key":"k","claim":"lesson","verified_by":"qa","expires_at":"2099-01-01T00:00:00Z"}' > "$D/learning-records.jsonl"
if bash "$C" pre_completion >/dev/null 2>&1; then fail=$((fail+1)); echo "FAIL completion with missing phases"; else pass=$((pass+1)); fi
printf '%s\n' '{"phase":"PLAN","verdict":"PASS","tier1_only":false}' '{"phase":"EXECUTE","verdict":"PASS","tier1_only":false}' >> "$D/scores.jsonl"
if bash "$C" pre_completion >/dev/null 2>&1; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL complete evidence denied"; fi

# 5. Declared enum and pattern constraints are enforced at controller entry.
jq '.state="BOGUS"' "$D/contract.json" > "$D/bad-state.json"
CONTRACT_FILE="$D/bad-state.json" bash "$C" pre_tool_action --tool edit --target "$D/README.md" >/dev/null 2>&1 && \
  { fail=$((fail+1)); echo "FAIL bad state enum accepted"; } || pass=$((pass+1))
jq '.score.verdict="MEH"' "$D/contract.json" > "$D/bad-verdict.json"
CONTRACT_FILE="$D/bad-verdict.json" bash "$C" pre_tool_action --tool edit --target "$D/README.md" >/dev/null 2>&1 && \
  { fail=$((fail+1)); echo "FAIL bad score verdict accepted"; } || pass=$((pass+1))
jq '.contract_version="not-semver"' "$D/contract.json" > "$D/bad-ver.json"
CONTRACT_FILE="$D/bad-ver.json" bash "$C" pre_tool_action --tool edit --target "$D/README.md" >/dev/null 2>&1 && \
  { fail=$((fail+1)); echo "FAIL bad version pattern accepted"; } || pass=$((pass+1))

echo "T15 enforcement gates: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
