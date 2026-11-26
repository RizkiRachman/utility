import { guardTool, toolCompleted } from "./guard.js";

const v2 = {
  id: "workflow-guard",
  async setup(ctx) {
    if (!ctx.tool || typeof ctx.tool.hook !== "function") return;
    const directory = ctx.location?.directory || process.cwd();
    await ctx.tool.hook("execute.before", async (event) => {
      await guardTool(directory, event.tool, event.args ?? event.input ?? {});
    });
    await ctx.tool.hook("execute.after", async (event) => {
      await toolCompleted(directory, event.tool, event.args ?? event.input ?? {}, event.status || "completed");
    });
  },
};

const server = async ({ directory } = {}) => ({
  "tool.execute.before": async (input, output) => {
    await guardTool(directory || process.cwd(), input.tool, output?.args ?? {});
  },
  "tool.execute.after": async (input, output) => {
    await toolCompleted(directory || process.cwd(), input.tool, output?.args ?? {}, output?.status || "completed");
  },
});

export { v2, server };
export default { ...v2, server };
