# agents

Two independently built agent modules live here.

| Directory | What it is |
| --- | --- |
| `opencode/` | The OpenCode v2 Docker stack: the workflow-state-engine, lean-ctx as the access layer, six MCP servers, the offline pre-install store, and the engine source with its documentation. |
| `openui/` | The OpenUI preview service: a small web app plus an MCP bridge that render generated UI for human review. |

Each submodule has its own README with build and run instructions. The OpenCode stack is the main entry point; start at its [Quick Start](opencode/README.md#quick-start).
