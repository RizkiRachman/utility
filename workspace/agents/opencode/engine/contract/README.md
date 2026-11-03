# Contract

Orchestration envelope definitions for the Workflow State Engine: schema, seed templates, and state log template.

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

## Envelope Sections

The envelope (`contract.template.json`, version 0.8.0) has these sections:

| Section | Holds |
|---------|-------|
| `session` | Task id, session id, created/archived timestamps |
| `requirements` | Goal, acceptance criteria, constraints |
| `decisions` | Approved architecture, coding standard, rejected approaches, ADR log, DDD flag, confidence scores |
| `governance` | Active agent, mode, rules references, guidance, permissions (allowed/denied tools, read-only vs writeable fields) |
| `scope` | Included and excluded paths, boundary, parallel execution settings |
| `score` | Three tiers: rule checks, judge, combined verdict |
| `retry` | Attempt counter, thresholds (escalate below 50, pass at 70 or above), per-phase issues, escalation trace |
| `outputs` | Plan, code changes, test results, agent reports, debt ledger |
| `metrics` | Token cost, elapsed time, agents used, phases completed |
| `token_budget` | Session and phase token limits |
| `validation` | Block conditions (test failures, score drops, compile errors), phase gates |
| `lessons_learned`, `audit_log` | Cross-session learning and the append-only action history (read-only fields) |

## Example Envelope

Trimmed from `contract.template.json` (no secrets; see the template for every field):

```json
{
  "$schema": "../contract/contract.schema.json",
  "version": "0.8.0",
  "state": "INIT",
  "session": {
    "task_id": "",
    "session_id": "",
    "created_at": "",
    "archived_at": null
  },
  "requirements": {
    "goal": "",
    "acceptance_criteria": [],
    "constraints": []
  },
  "score": {
    "rules": { "pass": 0, "fail": 0, "deduction": 0, "subtotal": 0 },
    "judge": { "score": 0, "rationale": "", "missing_items": [] },
    "combined": 0,
    "verdict": "INIT"
  },
  "retry": {
    "attempt": 0,
    "max_attempts": 3,
    "score_threshold": 70,
    "escalation_threshold": 50
  },
  "lessons_learned": [],
  "audit_log": [],
  "contract_version": "0.8.0"
}
```

## Validation

Validate any envelope file (run from the project root, `workspace/agents/opencode`):

```bash
bash engine/scripts/validate-contract.sh --file engine/contract/contract.template.json --score
```

`--score` applies the three-tier rule checks and prints a verdict. Scores below 50 block; 50-69 retries; 70 or above passes.

## Runtime Access

At runtime the contract definitions are exposed through the config symlink
`~/.config/opencode/contract` → `/opt/engine/contract/`, so agents read them as
`/opt/engine/contract/contract.schema.json`.
