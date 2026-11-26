import { guardTool } from "./guard.js";

// OpenCode 2: imperative hook registration from setup().
const v2 = {
  id: "workflow-guard",
  async setup(ctx) {
    if (!ctx.tool || typeof ctx.tool.hook !== "function") return;
    const directory = ctx.location?.directory || process.cwd();
    await ctx.tool.hook("execute.before", async (event) => {
      await guardTool(directory, event.tool, event.args ?? event.input ?? {});
    });
  },
};

// OpenCode 1: declarative hook map returned from server().
const server = async ({ directory } = {}) => ({
  "tool.execute.before": async (input, output) => {
    await guardTool(directory || process.cwd(), input.tool, output?.args ?? {});
  },
});

export { v2, server };
export default { ...v2, server };
