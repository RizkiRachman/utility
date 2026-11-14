# workspace

The runtime workspace for the OpenCode stack: agent sources, TLS certificates, workspace-level documents, infrastructure service definitions, the offline package store, and the agent sandbox.

This folder is the `workspace/` directory of the utility repository. Files that belong to the repo root (the compose file, the CI workflows, the repository README) sit one level up. Agents see only this folder, so this README is the map for everything an agent can touch.

## Directories

| Directory | What it holds |
| --- | --- |
| `agents/` | The two agent modules: the OpenCode stack (`opencode/`) and the OpenUI preview service (`openui/`). |
| `certs/` | Single source for corporate CA certificates, mirrored into the submodule Docker builds. |
| `documentation/` | Workspace-level documents: operational notes, analysis reports, cross-module decisions. |
| `infrastructure/` | Docker service definitions grouped by concern: databases, dashboards, load tests, secrets. |
| `pre-installer/` | Offline package store for image builds (apt, git, npm, pip) plus the tools that populate it. |
| `sandbox/` | Per-session agent scratch space. Session-local, never committed. |
| `tools/` | Helper scripts and small binaries that serve the whole stack. |

## Where to start

- To run the stack: [agents/opencode/README.md](agents/opencode/README.md) (Quick Start section).
- For session rules and what agents may write: [sandbox/README.md](sandbox/README.md).
- For the engine's operating contract: [agents/opencode/engine/README.md](agents/opencode/engine/README.md).
