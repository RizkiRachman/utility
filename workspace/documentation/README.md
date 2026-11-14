# documentation

Workspace-level documents: operational notes, analysis reports, and decisions that apply across modules. Module-specific documentation lives inside each module; the engine's guides live under [agents/opencode/engine/doc/](../agents/opencode/engine/doc/README.md) with usage guides in [agents/opencode/engine/usage/](../agents/opencode/engine/usage/).

## Documents

| Document | What it covers |
| --- | --- |
| [drift-analysis-2026-11-14.md](drift-analysis-2026-11-14.md) | Drift analysis of the enforcement workflow (agents, MCP servers, skills, RAG, CocoIndex, plugins): findings, fixes applied on 2026-11-14, and open items. |

## Conventions

- One document per topic, dated in the filename when it is a point-in-time analysis.
- Cross-module decisions get recorded here even when the fix lands elsewhere, so the reasoning stays findable.
