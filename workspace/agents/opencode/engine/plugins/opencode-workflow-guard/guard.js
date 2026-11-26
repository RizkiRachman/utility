import { join } from "node:path";
import { existsSync, readFileSync, appendFileSync } from "node:fs";
import { spawnSync } from "node:child_process";

const GUARDED = new Set(["edit", "write", "patch"]);
const DELEGATE = new Set(["task", "subagent"]);
const SHELL = new Set(["bash", "shell", "ctx_shell"]);
const AUDIT = "session/tool-audit.jsonl";
const CONTROLLER = process.env.WORKFLOW_CONTROLLER || "/opt/engine/scripts/workflow-controller.sh";

function controllerEnv(base) {
  return { ...process.env, CONTRACT_FILE: join(base, "session", "contract.json") };
}

/** Invoke the central controller. A nonzero exit is a policy denial. */
function callController(base, flags) {
  if (!existsSync(CONTROLLER)) return null;
  const r = spawnSync("bash", [CONTROLLER, ...flags], {
    env: controllerEnv(base), encoding: "utf8", timeout: 3000,
  });
  if (r.error || r.status !== 0) {
    const why = (r.stderr || "").trim() || `${flags[0]} denied`;
    throw new Error(`WorkflowPolicy: ${why} (see session/workflow-audit.jsonl)`);
  }
  return r.stdout.trim();
}

function agentOf(args) {
  return args.agent || args.subagent_type || args.agent_type || args.subagent || null;
}

function fallbackState(base) {
  const contract = join(base, "session", "contract.json");
  if (!existsSync(contract)) return "INIT";
  try { return JSON.parse(readFileSync(contract, "utf8")).state || "INIT"; }
  catch { return "UNKNOWN"; }
}

/** Safety net when the deployed controller is absent (source checkout). */
function fallbackGate(base, tool, target) {
  const state = fallbackState(base);
  const entry = { ts: new Date().toISOString(), tool, state, target: target || null };
  try { appendFileSync(join(base, AUDIT), JSON.stringify(entry) + "\n"); } catch { /* best effort */ }
  if (state === "BLOCKED") throw new Error(`Workflow guard: contract state is BLOCKED; ${tool} disabled until user intervention.`);
  if (state === "UNKNOWN") throw new Error(`Workflow guard: contract unparseable; ${tool} blocked.`);
  if (GUARDED.has(tool) && target && /(^|\/)contract\.json$/.test(String(target))) {
    throw new Error("Workflow guard: direct contract.json write blocked; use transition.sh");
  }
}

export async function guardTool(directory, tool, args = {}) {
  const base = directory || process.cwd();

  // Shell is audit-only except for the one policy-critical case: a command
  // that writes the live contract, which must go through transition.sh.
  if (SHELL.has(tool)) {
    const cmd = String(args.command || "");
    if (/contract\.json/.test(cmd) && /(>|>>|\bmv\b|\bcp\b|\btee\b|sed -i|\bjq\b)/.test(cmd)) {
      throw new Error("WorkflowPolicy: direct contract.json write via shell is blocked; use transition.sh");
    }
    return;
  }

  // Delegation must be authorized by agent identity in the current state.
  if (DELEGATE.has(tool)) {
    const agent = agentOf(args);
    if (!agent) throw new Error("WorkflowPolicy: delegation requires an agent identity");
    if (callController(base, ["pre_delegation", "--agent", agent]) === null) fallbackGate(base, tool, agent);
    return;
  }

  if (!GUARDED.has(tool)) return;
  const target = args.filePath || args.path || args.file || null;
  const flags = ["pre_tool_action", "--tool", tool];
  if (target) flags.push("--target", String(target));
  if (callController(base, flags) === null) fallbackGate(base, tool, target);
}

export async function toolCompleted(directory, tool, args = {}, status = "completed") {
  const base = directory || process.cwd();
  if (DELEGATE.has(tool)) {
    const agent = agentOf(args);
    if (agent) callController(base, ["post_delegation", "--agent", agent]);
  } else if (GUARDED.has(tool)) {
    if (callController(base, ["post_tool_action", "--tool", tool, "--status", status]) === null) {
      try { appendFileSync(join(base, AUDIT), JSON.stringify({ ts: new Date().toISOString(), tool, status }) + "\n"); } catch { /* best effort */ }
    }
  }
}
