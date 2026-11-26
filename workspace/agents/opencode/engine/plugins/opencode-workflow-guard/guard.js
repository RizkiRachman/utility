import { join } from "node:path";
import { existsSync, readFileSync, appendFileSync } from "node:fs";

const GUARDED = new Set(["edit", "write", "patch", "task", "subagent"]);
const AUDIT = "session/tool-audit.jsonl";

/**
 * Mechanical pre-tool-action gate. Runs for both OpenCode 1 (tool.execute.before)
 * and OpenCode 2 (ctx.tool.hook). Never throws in a source checkout with no live
 * contract; blocks when the contract is BLOCKED or cannot be parsed.
 */
export async function guardTool(directory, tool, args = {}) {
  if (!GUARDED.has(tool)) return;
  const base = directory || process.cwd();
  const contract = join(base, "session", "contract.json");

  let state = "INIT";
  if (existsSync(contract)) {
    try {
      state = JSON.parse(readFileSync(contract, "utf8")).state || "INIT";
    } catch {
      state = "UNKNOWN";
    }
  }

  const entry = {
    ts: new Date().toISOString(),
    tool,
    state,
    target: args.filePath || args.path || args.agent || null,
  };
  try {
    appendFileSync(join(base, AUDIT), JSON.stringify(entry) + "\n");
  } catch {
    // audit is best-effort; a missing session/ dir must not block work
  }

  if (state === "BLOCKED") {
    throw new Error(
      `Workflow guard: contract state is BLOCKED; ${tool} is disabled until user intervention.`
    );
  }
  if (state === "UNKNOWN") {
    throw new Error(
      `Workflow guard: session/contract.json is unparseable; ${tool} blocked until the contract is valid.`
    );
  }
}
