import { join } from "node:path";
import { existsSync, readFileSync, appendFileSync } from "node:fs";
import { execFileSync } from "node:child_process";

const GUARDED = new Set(["edit", "write", "patch", "task", "subagent"]);
const AUDIT = "session/tool-audit.jsonl";
const CONTROLLER = "/opt/engine/scripts/workflow-controller.sh";

function controllerEnv(base) {
  return { ...process.env, CONTRACT_FILE: join(base, "session", "contract.json") };
}

/** Post-tool-action audit via the central controller (best effort). */
export async function toolCompleted(directory, tool, status = "completed") {
  if (!GUARDED.has(tool) || !existsSync(CONTROLLER)) return;
  const flags = ["post_tool_action", "--tool", tool, "--status", status];
  try {
    execFileSync("bash", [CONTROLLER, ...flags], {
      env: controllerEnv(directory || process.cwd()), stdio: "ignore", timeout: 3000,
    });
  } catch { /* audit is best effort; never fail a completed tool */ }
}

/**
 * Mechanical pre-tool-action gate. The central controller is authoritative when
 * deployed; a built-in check keeps the plugin safe in source checkouts where
 * the controller is absent.
 */
export async function guardTool(directory, tool, args = {}) {
  if (!GUARDED.has(tool)) return;
  const base = directory || process.cwd();

  if (existsSync(CONTROLLER)) {
    const target = args.filePath || args.path || args.agent;
    const flags = ["pre_tool_action", "--tool", tool];
    if (target) flags.push("--target", String(target));
    let denied = false;
    try {
      execFileSync("bash", [CONTROLLER, ...flags], {
        env: controllerEnv(base), stdio: "ignore", timeout: 3000,
      });
    } catch { denied = true; }
    if (denied) {
      throw new Error(
        `WorkflowPolicy: ${tool} blocked by workflow-controller.sh (see session/workflow-audit.jsonl)`
      );
    }
    return;
  }

  // Fallback for checkouts without the deployed controller.
  const contract = join(base, "session", "contract.json");
  let state = "INIT";
  if (existsSync(contract)) {
    try { state = JSON.parse(readFileSync(contract, "utf8")).state || "INIT"; }
    catch { state = "UNKNOWN"; }
  }
  const entry = { ts: new Date().toISOString(), tool, state, target: args.filePath || args.path || args.agent || null };
  try { appendFileSync(join(base, AUDIT), JSON.stringify(entry) + "\n"); } catch { /* best effort */ }
  if (state === "BLOCKED") throw new Error(`Workflow guard: contract state is BLOCKED; ${tool} is disabled until user intervention.`);
  if (state === "UNKNOWN") throw new Error(`Workflow guard: session/contract.json is unparseable; ${tool} blocked until the contract is valid.`);
}
