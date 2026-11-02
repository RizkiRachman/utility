# Contract: Workflow State Engine Definitions

This folder defines the orchestration contract for AI agent workflows.
**All files here are version-controlled definitions**: no runtime state.

| File | Purpose |
|------|---------|
| `README.md` | This file: overview of the contract/ folder |
| `contract.schema.json` | JSON Schema (Draft 2020-12) validating the orchestration envelope |
| `contract.template.json` | Seed envelope with default values: agents use this as the base for new sessions via `lean-ctx ctx_knowledge` |
| `meta-contract.template.json` | Seed template for meta-contracts: tracks cross-service integration state for root-orchestrator orchestration |
| `state.template.md` | Template for session state tracking: copied to `session/state.md` on seed |
| `state.md` | Engine-local seeded copy of the above: a working copy, not the template |

The live runtime contract lives at project-root `session/contract.json` (gitignored),
with `session/state.md` as its companion state log.
`scripts/snapshot-contract.sh` seeds, validates, and archives these per session.

## Runtime Access

At runtime the contract definitions are exposed through the config symlink
`~/.config/opencode/contract` → `/opt/engine/contract/`, so agents read them as
`/opt/engine/contract/contract.schema.json`.
