<!-- omit from toc -->
# Workflow State Engine -- Orchestration Toolkit

[![Project Status](https://img.shields.io/badge/status-active-brightgreen?style=for-the-badge)](https://github.com/RizkiRachman/workflow-state-engine)
[![GitHub](https://img.shields.io/badge/GitHub-181717?style=for-the-badge&logo=github)](https://github.com/RizkiRachman/workflow-state-engine)

**Contract-driven state machine orchestration engine for AI agent workflows.** A shared JSON envelope (`session/contract.json`) drives an 8-state state machine that coordinates a 15-member scrum team of specialized AI agents across requirements, planning, execution, review, and process phases. Built for multi-agent orchestration with per-phase multi-model review, three-tier scoring, cross-session learning, and audit-grade observability.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Tech Stack

- **Language**: Markdown, JSON, Shell
- **Framework**: None -- doc-driven orchestration toolkit
- **Architecture**: Contract-driven state machine (agents/ -> skills/ -> contract/)
- **Storage**: `session/contract.json` (per-session shared envelope) + `ctx_knowledge` (cross-session persistence)
- **API Spec**: `contract/contract.schema.json` (canonical envelope schema)

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Core Concepts

| Concept | Description |
|---------|-------------|
| **Shared JSON Envelope** | `session/contract.json` -- per-session single source of truth for state, decisions, scoring, and outputs across all agents |
| **State Machine** | 8 states: `INIT -> PLAN -> PLAN_SCORED -> EXECUTE -> EXECUTE_SCORED -> REVIEW -> REVIEW_SCORED -> COMPLETE` (+ `BLOCKED` escalation) |
| **Scoring Pipeline** | Three-tier: Rule-based checks (Tier 1) -> LLM-as-Judge (Tier 2) -> Combined Verdict of PASS / RETRY / BLOCKED (Tier 3) |
| **Scoring Thresholds** | PASS >= 70, RETRY 50-69 (max 3 attempts), BLOCKED < 50 |
| **15 Agent Types (scrum team)** | Orchestrator/lead (orchestrator), product (product-manager), process (scrum-master), planners (system-analyst, software-architect), implementers (developer, devops-engineer, fixer), reviewers (quality-analyst, security-engineer, learner), support (explorer, librarian, council, observer) |
| **Cross-Model Review** | Executors run on `opencode/big-pickle`; reviewers run on an independent model (`sumopod/deepseek-flash`). Conflicting verdicts → `BLOCKED`, arbitrated by `council` (`rules.json → enforcement.cross_model_review`) |
| **50 Skill Directories** | Runnable skills including java-developer, system-analyst, writing-plans, spec-driven-development, test-driven-development, brainstorming, qa-expert, security-expert, devops-expert, and more |
| **Cross-Session Learning** | Lessons, patterns, and gotchas persisted via `ctx_knowledge` -- survives session restarts and spans sessions |

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Getting Started

The engine ships inside the container image, so getting it running is build → configure → run:

```bash
docker build -t workflow-state-engine .   # copies engine/ -> /opt/engine/ and symlinks into ~/.config/opencode/
cp config/opencode.proposed.json config/opencode.json   # then fill in API-key placeholders
docker run --rm -it -e OPENCODE_API_KEY="<your-key>" \
  -v "$PWD/config/opencode.json":/home/node/.config/opencode/opencode.json:ro \
  -p 4096:4096 workflow-state-engine
```

Then connect to OpenCode (web UI on port 4096). The orchestrator (orchestrator agent) reads `session/contract.json` on start. See [`doc/workflow.md`](workflow.md) for the full state machine and scoring reference.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Architecture

The toolkit is organized as a **3-layer framework** of agents, skills, and contracts:

- **`agents/` (16 agents)** -- Specialized instruction files defining role, state machine access, MCP permissions, and post-flight protocol. The orchestrator orchestrator leads a scrum team (product-manager, scrum-master, system-analyst, software-architect, developer, devops-engineer, fixer, quality-analyst, security-engineer, learner + support agents) in a spec-driven development (SDD) flow: Refine -> Plan -> Spec Gate -> Execute -> Review -> Process Gate -> Ship.

- **`skills/` (50 directories)** -- Runnable skill libraries providing deep guidance per domain. Each skill directory contains a `SKILL.md` with workflows, conventions, and quality gates. Loaded on demand via `/skill` when a task matches the skill's domain.

- **`contract/` (contract templates)** -- `contract.template.json` is the template for per-session envelopes. Live state lives at `session/contract.json`, which persists state transitions, decisions, scoring results, token budgets, and audit logs. `contract.schema.json` is the canonical API schema. Cross-session memory lives in `ctx_knowledge` for durable pattern learning.

- **Before-Commit Protocol** -- Every session runs: impact verify (`ctx_impact`) -> change detect (`ctx_delta`) -> knowledge persist (`ctx_knowledge remember`) -> graphify sync -> `session/state.md` update -> session save (all 6 systems). `session/` and `.session/` are LOCAL-ONLY runtime state — never commit or push them.

- **Doubt-Driven Development (DDD)** -- Non-trivial decisions get a fresh-context adversarial review before they stand. Used for correctness-critical, high-stakes, or unfamiliar-code decisions.

- **Spec-Driven Development (SDD)** -- Tasks crossing >3 files, multiple services, or estimated >30 min require GWT-format specs written before implementation begins. Specs are cross-examined via DDD before coding starts.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Reference Links

| Resource | Description |
|----------|-------------|
| [`agent.md`](../agent.md) | Main orchestrator instructions -- loaded by every agent at session start |
| [`doc/workflow.md`](workflow.md) | Canonical state machine, scoring pipeline, gates, and validation rules |
| [`doc/skill-conventions.md`](skill-conventions.md) | Skill authoring conventions |
| `session/contract.json` | Per-session orchestration envelope (live state) |
| [`contract/contract.schema.json`](../contract/contract.schema.json) | Envelope JSON Schema |
| [`rules/rules.json`](../rules/rules.json) | State machine transitions and scoring rules |
| [`scripts/check-conventions.sh`](../scripts/check-conventions.sh) | Convention validation |
| [`scripts/validate-toolkit.sh`](../scripts/validate-toolkit.sh) | Full toolkit validation |