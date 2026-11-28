#!/usr/bin/env bash
# T14-plugin-registration.sh — guard registration is checked, not assumed.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$SCRIPT_DIR/../check-plugin-registration.sh"
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
mkdir -p "$D/plugin"
printf 'export const x = 1;\n' > "$D/plugin/guard.js"
printf 'export const y = 2;\n' > "$D/plugin/index.js"
printf '{"name":"workflow-guard"}\n' > "$D/plugin/package.json"
printf '{"plugins":["%s"]}' "$D/plugin" > "$D/ok.json"
printf '{"plugins":[]}' > "$D/empty.json"
pass=0; fail=0
run() { bash "$S" "$1" "$D/plugin" 2>/dev/null; return $?; }
check() {
  local label="$1" cfg="$2" key="$3" want="$4" out rc
  out=$(run "$cfg"); rc=$?
  got=$(printf '%s\n' "$out" | jq -r "$key")
  [[ "$got" == "$want" ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL $label: $key expected $want, got $got"; }
  echo "$rc" > "$D/last_rc"
}
check "registered" "$D/ok.json" ".status" "registered"
[[ "$(cat "$D/last_rc")" == "0" ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL registered rc"; }
check "not registered" "$D/empty.json" ".status" "not_registered"
[[ "$(cat "$D/last_rc")" == "1" ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL not registered rc"; }
check "config missing" "$D/nope.json" ".status" "config_missing"
[[ "$(cat "$D/last_rc")" == "2" ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL missing rc"; }
out=$(env PATH=/usr/bin:/bin bash "$S" "$D/ok.json" "$D/plugin" 2>/dev/null); rc=$?
[[ "$(printf '%s' "$out" | jq -r '.node_available')" == "false" && "$rc" == "1" ]] && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL node unavailable rc/flag"; }
rm "$D/plugin/index.js"
check "files missing" "$D/ok.json" ".status" "files_missing"

# Guard shape probe: names are normalized by token, so any MCP host prefix
# works; setup() must register both hooks and leave an armed heartbeat.
GUARD="$SCRIPT_DIR/../../plugins/opencode-workflow-guard"
if command -v node >/dev/null 2>&1; then
  out=$(node --input-type=module - "$GUARD" "$D" <<'NODE'
import { pathToFileURL } from "node:url";
const [dir, tmp] = process.argv.slice(2);
const g = await import(pathToFileURL(dir + "/guard.js").href);
const mod = await import(pathToFileURL(dir + "/index.js").href);
const cases = [
  ["shell", "bash", true], ["shell", "ctx_shell", true],
  ["shell", "server_ctx_shell", true], ["shell", "context7_query_docs", false],
  ["guarded", "edit", true], ["guarded", "server_ctx_patch", true],
  ["guarded", "read", false],
  ["delegate", "subagent", true], ["delegate", "server_task", true],
  ["delegate", "context7_query_docs", false],
];
let fail = 0;
for (const [kind, tool, want] of cases) {
  const got = kind === "shell" ? g.isShellTool(tool)
    : kind === "guarded" ? g.isGuardedTool(tool) : g.isDelegateTool(tool);
  if (got !== want) { console.log("FAIL normalize", kind, tool, "got", got); fail++; }
}
if (g.targetOf({ path: "x" }) !== "x" || g.targetOf({ file_path: "y" }) !== "y") {
  console.log("FAIL targetOf"); fail++;
}
const hooks = [];
await mod.v2.setup({ tool: { hook: async (name) => hooks.push(name) }, location: { directory: tmp } });
if (!hooks.includes("execute.before") || !hooks.includes("execute.after")) {
  console.log("FAIL hooks", hooks.join(",")); fail++;
}
const { readFileSync } = await import("node:fs");
if (!readFileSync(tmp + "/session/tool-audit.jsonl", "utf8").includes("guard_armed")) {
  console.log("FAIL heartbeat"); fail++;
}
process.exit(fail ? 1 : 0);
NODE
  ) && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL guard normalization/arming probe: $out"; }

  # End-to-end: an MCP-prefixed tool name must reach the controller and be
  # denied on protected artifacts. Bare-name sets used to miss this entirely.
  mkdir -p "$D/session"
  cp "$SCRIPT_DIR/../../contract/contract.template.json" "$D/session/contract.json"
  out=$(WORKFLOW_CONTROLLER="$SCRIPT_DIR/../workflow-controller.sh" node --input-type=module - "$GUARD" "$D" <<'NODE'
import { pathToFileURL } from "node:url";
const [dir, tmp] = process.argv.slice(2);
const { guardTool } = await import(pathToFileURL(dir + "/guard.js").href);
let fail = 0;
async function denied(label, tool, args) {
  try { await guardTool(tmp, tool, args); console.log("FAIL allowed", label); fail++; }
  catch { /* expected denial */ }
}
await denied("namespaced patch to contract.json", "lean-ctx_ctx_patch", { file_path: `${tmp}/session/contract.json` });
await denied("namespaced shell write to contract.json", "lean-ctx_ctx_shell", { command: `echo x > ${tmp}/session/contract.json` });
const { readFileSync } = await import("node:fs");
const log = readFileSync(`${tmp}/session/workflow-audit.jsonl`, "utf8");
if (!log.includes("pre_tool_action") || !log.includes("pre_shell")) { console.log("FAIL no controller audit"); fail++; }
process.exit(fail ? 1 : 0);
NODE
  ) && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL namespaced end-to-end gate: $out"; }
fi
echo "T14 plugin registration: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
