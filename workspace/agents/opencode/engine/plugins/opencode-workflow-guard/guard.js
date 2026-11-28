import { basename, dirname, join, resolve } from "node:path";
import { createHash } from "node:crypto";
import { existsSync, readFileSync, appendFileSync, realpathSync } from "node:fs";
import { spawnSync } from "node:child_process";

// Match on name tokens, never exact names: MCP hosts prefix tools with a
// server name (server_ctx_shell, server_ctx_patch). No host is special-cased.
const toolParts = (tool) => String(tool || "").toLowerCase().split(/[^a-z0-9]+/);
const isShellTool = (tool) => toolParts(tool).some((p) => p === "bash" || p === "shell");
const isDelegateTool = (tool) => toolParts(tool).some((p) => p === "task" || p === "subagent");
const isGuardedTool = (tool) => toolParts(tool).some((p) => p === "edit" || p === "write" || p === "patch");
const targetOf = (args) => args.filePath || args.file_path || args.path || args.file || args.filename || args.target || null;
const AUDIT = "session/tool-audit.jsonl";
const CONTROLLER = process.env.WORKFLOW_CONTROLLER || "/opt/engine/scripts/workflow-controller.sh";

function controllerEnv(base) {
  return { ...process.env, CONTRACT_FILE: join(base, "session", "contract.json") };
}

/** Invoke the central controller. A nonzero exit is a policy denial. */
function callController(base, flags) {
  if (!existsSync(CONTROLLER)) return null;
  for (let attempt = 0; attempt < 2; attempt++) {
    const r = spawnSync("bash", [CONTROLLER, ...flags], {
      env: controllerEnv(base), encoding: "utf8", timeout: 3000,
    });
    const timedOut = r.error?.code === "ETIMEDOUT";
    if (timedOut && attempt === 0) continue; // transient scheduler stall: retry once
    if (r.error || r.status !== 0) {
      const why = (r.stderr || "").trim() || (timedOut ? "controller timed out" : `${flags[0]} denied`);
      throw new Error(`WorkflowPolicy: ${why} (see session/workflow-audit.jsonl)`);
    }
    return r.stdout.trim();
  }
}

function agentOf(args) {
  return args.agent || args.subagent_type || args.agent_type || args.subagent || null;
}

function stableStringify(value) {
  if (value === undefined) return "null";
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${stableStringify(value[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

function fallbackState(base) {
  const contract = join(base, "session", "contract.json");
  if (!existsSync(contract)) return "INIT";
  try { return JSON.parse(readFileSync(contract, "utf8")).state || "INIT"; }
  catch { return "UNKNOWN"; }
}

function fallbackProtectedTarget(target) {
  const resolved = resolve(String(target));
  let canonical = resolved;
  try { canonical = realpathSync.native(resolved); }
  catch {
    try { canonical = join(realpathSync.native(dirname(resolved)), basename(resolved)); } catch { /* use normalized path */ }
  }
  const parts = canonical.replaceAll("\\", "/").split("/");
  const name = parts[parts.length - 1];
  return name.startsWith(".env") ||
    new Set(["contract.json", "scores.jsonl", "workflow-audit.jsonl", "tool-audit.jsonl", "loop-state.json", "opencode.json"]).has(name) ||
    parts.includes(".session");
}

/** Safety net when the deployed controller is absent (source checkout). */
function fallbackGate(base, tool, target) {
  const state = fallbackState(base);
  const entry = { ts: new Date().toISOString(), tool, state, target: target || null };
  try { appendFileSync(join(base, AUDIT), JSON.stringify(entry) + "\n"); } catch { /* best effort */ }
  if (state === "BLOCKED") throw new Error(`Workflow guard: contract state is BLOCKED; ${tool} disabled until user intervention.`);
  if (state === "UNKNOWN") throw new Error(`Workflow guard: contract unparseable; ${tool} blocked.`);
  if (isGuardedTool(tool) && target && fallbackProtectedTarget(target)) {
    throw new Error("Workflow guard: direct write to a protected workflow artifact blocked");
  }
}

const PROTECTED_SHELL = ["contract.json", ".env", "opencode.json", ".session/", "workflow-audit.jsonl", "tool-audit.jsonl", "scores.jsonl", "loop-state.json"];
const WRITE_OPERATOR = /(>|>>|\bmv\b|\bcp\b|\btee\b|sed -i|\brm\b|\bchmod\b|\bchown\b)/;
function fallbackShellWrite(cmd) {
  return WRITE_OPERATOR.test(cmd) && PROTECTED_SHELL.some((p) => cmd.includes(p));
}

export async function guardTool(directory, tool, args = {}) {
  const base = directory || process.cwd();

  // Shell writes to policy artifacts are denied by the central controller;
  // the inline check is a fallback when the deployed controller is absent.
  if (isShellTool(tool)) {
    const cmd = String(args.command || "");
    if (callController(base, ["pre_shell", "--command", cmd]) === null && fallbackShellWrite(cmd)) {
      throw new Error("WorkflowPolicy: shell write to a protected artifact is blocked; use transition.sh");
    }
    return;
  }

  // Delegation must be authorized by agent identity in the current state.
  if (isDelegateTool(tool)) {
    const agent = agentOf(args);
    if (!agent) throw new Error("WorkflowPolicy: delegation requires an agent identity");
    const attemptHash = createHash("sha256").update(stableStringify(args)).digest("hex");
    if (callController(base, ["pre_delegation", "--agent", agent, "--attempt-hash", attemptHash]) === null) fallbackGate(base, tool, agent);
    return;
  }

  if (!isGuardedTool(tool)) return;
  const target = targetOf(args);
  const flags = ["pre_tool_action", "--tool", tool];
  if (target) flags.push("--target", String(target));
  if (callController(base, flags) === null) fallbackGate(base, tool, target);
}

export async function toolCompleted(directory, tool, args = {}, status = "completed") {
  const base = directory || process.cwd();
  if (isDelegateTool(tool)) {
    const agent = agentOf(args);
    if (agent) callController(base, ["post_delegation", "--agent", agent]);
  } else if (isShellTool(tool)) {
    if (callController(base, ["post_shell", "--command", String(args.command || "")]) === null) {
      try { appendFileSync(join(base, AUDIT), JSON.stringify({ ts: new Date().toISOString(), tool, status }) + "\n"); } catch { /* best effort */ }
    }
  } else if (isGuardedTool(tool)) {
    if (callController(base, ["post_tool_action", "--tool", tool, "--status", status]) === null) {
      try { appendFileSync(join(base, AUDIT), JSON.stringify({ ts: new Date().toISOString(), tool, status }) + "\n"); } catch { /* best effort */ }
    }
  }
}

export { isShellTool, isDelegateTool, isGuardedTool, targetOf };
