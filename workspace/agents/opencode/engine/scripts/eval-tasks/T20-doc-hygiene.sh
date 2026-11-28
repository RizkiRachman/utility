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
ok "mcp servers configured" "$mcps" "5"
for srv in context7 falkordb fetch lean-ctx rag; do
  grep -q "$srv" "$ROOT/README.md" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL mcp name in root README: $srv"; }
done
removed=$(jq -r '.mcp.servers | has("openui") or has("cocoindex-code")' "$ROOT/config/opencode.json" 2>/dev/null)
ok "openui and cocoindex-code stay unregistered" "$removed" "false"

# 3. Freshness markers (tip 35334f4).
[[ -f "$ENGINE/scripts/gen-skills-manifest.sh" ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL gen-skills-manifest.sh missing"; }
[[ -f "$ENGINE/doc/generate_diagrams.py" ]] && { fail=$((fail+1)); echo "FAIL generate_diagrams.py must be absent"; } || pass=$((pass+1))
svgs=$(find "$ENGINE/doc" -name '*.svg' 2>/dev/null | wc -l | tr -d ' ')
ok "no generated svgs in doc" "$svgs" "0"

# 4. Entry-point and score-gate markers stay findable.
grep -q '^## Architecture' "$ENGINE/README.md" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL Architecture section"; }
grep -q '50-69 RETRY' "$ENGINE/README.md" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL score-gate sentence"; }
[[ -f "$ROOT/docs/git-mirrors.md" ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL docs/git-mirrors.md missing"; }

# 5. Diagram freshness markers stay in place (mermaid only, no binary images).
grep -q 'flowchart LR' "$ROOT/README.md" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL flowchart LR in root README"; }
grep -q 'stateDiagram-v2' "$ENGINE/README.md" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL state machine mermaid block"; }
imgs=$(grep -cE '!\[[^]]*\]\(' "$ENGINE/README.md" 2>/dev/null || true)
ok "no image links in engine README" "$imgs" "0"

# 6. Every "N MCP servers" claim in engine markdown matches the config count.
mcps=$(jq -r '.mcp.servers | keys | length' "$ROOT/config/opencode.json" 2>/dev/null)
bad=$(grep -rhoE '[0-9]+ MCP servers' "$ENGINE" --include='*.md' 2>/dev/null | grep -oE '^[0-9]+' | grep -vc "^$mcps\$" || true)
ok "mcp count claims match config" "$bad" "0"

grep -q 'Inventory is pinned' "$ENGINE/README.md" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL inventory boundary note"; }

[[ -f "$ROOT/../../ai/mcp/falkordb/Dockerfile" && -f "$ROOT/../../ai/mcp/falkordb/docker-compose.example.yaml" ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL kg container files missing"; }

grep -q 'bpg.group: infra' "$ROOT/../../ai/mcp/falkordb/docker-compose.example.yaml" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL kg compose missing house labels"; }
grep -q '^  falkordb:' "$ROOT/../../../docker-compose.example.yaml" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL falkordb service missing in root compose"; }

[[ ! -e "$ROOT/../../ai/mcp/cocoindex-code" ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL ccc container dir still present"; }
grep -q 'cocoindex-code' "$ROOT/../../../docker-compose.example.yaml" && { fail=$((fail+1)); echo "FAIL cocoindex-code still referenced in parent compose"; } || pass=$((pass+1))
grep -q '^ast-grep=' "$ROOT/pre-install/versions.lock" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL ast-grep pin missing in versions.lock"; }

echo "T20 doc hygiene: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
