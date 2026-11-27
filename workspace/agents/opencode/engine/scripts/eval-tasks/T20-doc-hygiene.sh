#!/usr/bin/env bash
# T20-doc-hygiene.sh - engine docs carry no em dashes, and advertised
# inventory counts match the tree and config they describe.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE="$(cd "$SCRIPT_DIR/../.." && pwd)"          # .../workspace/agents/opencode/engine
ROOT="$(cd "$ENGINE/.." && pwd)"                   # .../workspace/agents/opencode
pass=0; fail=0
ok() { [[ "$2" == "$3" ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $1: expected $3, got $2"; }; }

# 1. No U+2014 anywhere in engine markdown. Vendored plugin skills are
#    third-party content and are out of scope.
dashes=$(grep -rl $'\u2014' "$ENGINE" --include='*.md' 2>/dev/null | grep -v '/plugins/' | wc -l | tr -d ' ')
ok "no em dashes in engine md" "$dashes" "0"

# 2. Advertised counts match reality (agents, skills, MCP servers).
agents=$(ls "$ENGINE"/agents/*.md 2>/dev/null | wc -l | tr -d ' ')
skills=$(find "$ENGINE/skills" -mindepth 2 -maxdepth 2 -name 'SKILL.md' 2>/dev/null | wc -l | tr -d ' ')
mcps=$(jq -r '.mcp.servers | keys | length' "$ROOT/config/opencode.json" 2>/dev/null)
claimed_agents=$(grep -oE '[0-9]+ agents' "$ENGINE/README.md" 2>/dev/null | head -1 | grep -oE '[0-9]+')
claimed_skills=$(grep -oE '[0-9]+ skills' "$ENGINE/README.md" 2>/dev/null | head -1 | grep -oE '[0-9]+')
ok "agents advertised" "${claimed_agents:-unset}" "$agents"
ok "skills advertised" "${claimed_skills:-unset}" "$skills"
ok "mcp servers configured" "$mcps" "6"
for srv in cocoindex-code context7 fetch lean-ctx openui rag; do
  grep -q "$srv" "$ROOT/README.md" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL mcp name in root README: $srv"; }
done

# 3. Freshness markers (tip 35334f4).
[[ -f "$ENGINE/scripts/gen-skills-manifest.sh" ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL gen-skills-manifest.sh missing"; }
[[ -f "$ENGINE/doc/generate_diagrams.py" ]] && { fail=$((fail+1)); echo "FAIL generate_diagrams.py must be absent"; } || pass=$((pass+1))
svgs=$(find "$ENGINE/doc" -name '*.svg' 2>/dev/null | wc -l | tr -d ' ')
ok "no generated svgs in doc" "$svgs" "0"

# 4. Entry-point and score-gate markers stay findable.
grep -q '^## Architecture' "$ENGINE/README.md" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL Architecture section"; }
grep -q '50-69 RETRY' "$ENGINE/README.md" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL score-gate sentence"; }
[[ -f "$ROOT/docs/git-mirrors.md" ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL docs/git-mirrors.md missing"; }

echo "T20 doc hygiene: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
