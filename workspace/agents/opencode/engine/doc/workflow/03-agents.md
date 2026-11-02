<!-- omit from toc -->

# Part C — Agent Integration Matrix

> See [doc/workflow/README.md](../workflow/README.md) for index.

This part maps all 16 agents (scrum team) to their contract states, MCPs, and skills. It also documents the toolkit data flow, agent pipeline, and cross-reference table for every concept in the orchestration system.

## C1. Full 15-Agent × 3-Dimension Table

| Agent | Contract States | Key MCPs | Skills to Load | Usage Pattern |
|---|---|---|---|---|
| **orchestrator** | all states | lean-ctx, context7, graphify | (orchestrator — agent.md) | delegate → score → persist |
| **product-manager** | INIT, PLAN | lean-ctx, context7 | business-analyst, brainstorming, writing-plans | intent → GWT criteria → scope |
| **scrum-master** | all, BLOCKED | lean-ctx, graphify | orchestration-template, audit-observability, adaptive-solver | audit → enforce → unblock |
| **system-analyst** | INIT, PLAN, PLAN_SCORED | lean-ctx, graphify | brainstorming, writing-plans, doubt-driven-development | analyze → plan/spec |
| **software-architect** | INIT, PLAN, PLAN_SCORED, REVIEW | lean-ctx, graphify | system-analyst, java-developer | independent design review |
| **developer** | EXECUTE, EXECUTE_SCORED | lean-ctx | test-driven-development, software-developer | implement spec → tests |
| **devops-engineer** | EXECUTE, EXECUTE_SCORED, REVIEW | lean-ctx | devops-expert, observability-and-instrumentation | pipeline → deploy → rollback |
| **fixer** | EXECUTE | lean-ctx | systematic-debugging | bounded fix |
| **quality-analyst** | REVIEW, REVIEW_SCORED | lean-ctx | code-review-and-quality, qa-expert, security-expert | review 5 axes |
| **security-engineer** | REVIEW, REVIEW_SCORED | lean-ctx | security-expert, code-review-and-quality | threat model → verdict |
| **explorer** | PLAN, REVIEW | lean-ctx, graphify | (exploration) | read-only code map |
| **librarian** | any | context7 | (research) | docs/library lookup |
| **council** | any (high-stakes) | lean-ctx, graphify | (multi-LLM consensus) | council_session → consensus → report |
| **observer** | any | lean-ctx | (visual analysis) | images / PDFs / diagrams |
| **learner** | COMPLETE | lean-ctx (knowledge) | verification-before-completion | extract lessons → knowledge |

## C2. Agent Profiles

- **orchestrator**: Orchestrator — delegates, scores, drives state machine. Highest privilege: read/write all contract fields.
- **product-manager**: Requirements owner — turns intent into testable GWT acceptance criteria and declares scope/non-goals. Read-only, reviewer model.
- **scrum-master**: Process owner — audits transitions, enforces gates and DoD, unblocks BLOCKED, drives retros. Read-only, reviewer model.
- **system-analyst**: Planner — analyzes, traces, produces specs/plans. Read-only: never writes code.
- **software-architect**: Architecture advisor and independent design reviewer — tradeoffs, system-level debugging, YAGNI. Read-only, reviewer model.
- **developer**: Builder — implements plan step by step, writes tests alongside code. Full write access.
- **devops-engineer**: Delivery specialist — CI/CD, containerization, deploy, migrations, observability, rollback. Read/write.
- **fixer**: Bounded fixer — fast, scoped edits for well-defined bugs. Minimal context, fast turnaround.
- **quality-analyst**: Reviewer — code quality, performance, DB, DevOps operability across 5 axes. Read-only, reviewer model.
- **security-engineer**: Security reviewer — threat model, vulns, secrets, trust boundaries. Cross-model reviewer, read-only.
- **explorer**: Codebase explorer — queries lean-ctx/graphify to understand unfamiliar code. Read-only.
- **librarian**: External researcher — context7 docs lookup, library research. Read-only.
- **council**: Consensus engine — multi-LLM deliberation and cross-model arbitration for high-stakes decisions. Read-only.
- **observer**: Visual analyst — images, PDFs, diagrams. Read-only.
- **learner**: Post-exec retro — extracts lessons, persists knowledge_updates[]. Read-only.

## C3. Toolkit Data Flow

### Data Flow Steps

```
1. User request
       │
2. orchestrator creates contract envelope
       │  (session/contract.json → lean-ctx knowledge)
       ▼
3. Envelope stored: lean-ctx ctx_knowledge remember key="orchestration-contract"
       │
4. orchestrator delegates: task({subagent_type: "system-analyst", prompt: "..."})
       │
5. Subagent reads envelope: lean-ctx ctx_knowledge recall --query "orchestration-contract"
       │
6. Subagent uses usage/<tool>.md for tool guidance
   Subagent loads skills/<name>/SKILL.md for skill instructions
       │
7. Subagent returns result (output structure depends on phase — plan, code, or report)
       │
8. orchestrator scores → updates envelope → persists → delegates next agent
       │
9. Loop: PLAN → EXECUTE → REVIEW → COMPLETE (or BLOCKED → retry)
```

**Step detail**:
- **Step 2-3**: The envelope is persisted as a JSON object under `lean-ctx ctx_knowledge` key `orchestration-contract`. It includes state, session metadata, requirements, decisions, scoring, retry info, outputs, and metrics.
- **Step 4-5**: Delegation uses OpenCode's subagent task mechanism. The subagent loads the envelope at session start (pre-flight protocol in all agent instruction files).
- **Step 8-9**: The orchestrator runs the scoring pipeline after every delegation. If PASS, advances state. If RETRY, re-delegates with issues. If BLOCKED, escalates to user.

### Agent Pipeline

```
                     agent.md (instructions[0])
                           │
                        orchestrator  (orchestrator, default_agent)
                           │
        ┌──────────┬───────┼────────┬───────────────┐
        ▼          ▼       ▼        ▼               ▼
   product-    system-  developer  quality-      scrum-master
   manager     analyst  devops-    analyst       (process gate,
   (refine)    (+ arch) engineer   security-      unblock BLOCKED)
        │          │       │       engineer          │
        └──────────┴───────┴────────┬────────────────┘
                                   ▼
                              learner (retro)
                                   │
                              usage/*.md
                        (guides loaded as needed)
```

Executor model: `opencode/big-pickle` · Reviewer model: `sumopod/deepseek-flash` · Arbitration: `council`.

The pipeline shows the hierarchy: `agent.md` is loaded by every agent at session start. Agents delegate down the pipeline (orchestrator → system-analyst → developer → quality-analyst), with usage guides loaded on demand by any agent.

### Folder → Workflow Mapping

```
├── agent.md                → Instructions[0] — loaded by EVERY agent at session start
├── agents/                 → Agent definitions loaded by opencode.json
├── skills/                 → Loaded on-demand via skill({name: "skill-name"})
├── usage/                  → Loaded on-demand when agent encounters an unfamiliar tool
├── contract/               → Contract templates (contract.template.json, contract.schema.json, state.md)
├── rules/                  → rules.json — state machine transitions + scoring thresholds
└── doc/                    → Planning/reporting documents (never loaded automatically)
```

### Tool Selection by Phase

| Phase | Agent | Primary Tools | Skills Loaded |
|---|---|---|---|
| INIT → PLAN | product-manager → system-analyst | ctx_impact, ctx_compose, context7, graphify | business-analyst, brainstorming, writing-plans, doubt-driven-development |
| PLAN_SCORED | orchestrator (+ software-architect review) | lean-ctx (scoring), lean-ctx (persist) | spec-driven-development (SDD gate) |
| EXECUTE | developer (+ devops-engineer, fixer) | ctx_impact, lean-ctx (write) | test-driven-development, devops-expert, observability-and-instrumentation |
| EXECUTE_SCORED | orchestrator | lean-ctx (scoring) | doubt-driven-development (DDD gate), over-engineering check |
| REVIEW | quality-analyst + security-engineer | lean-ctx (read), lean-ctx (impact) | code-review-and-quality, qa-expert, security-expert |
| REVIEW_SCORED | orchestrator (+ scrum-master DoD gate) | lean-ctx (scoring + persist) | verification-before-completion |
| COMPLETE | learner | lean-ctx (knowledge), lean-ctx (detect) | verification-before-completion, software-developer |
| BLOCKED | scrum-master | lean-ctx (audit), ctx_impact | orchestration-template, adaptive-solver, audit-observability |

### Cross-Reference Table

| Concept | Definition | Configured In | Loaded By |
|---|---|---|---|
| Envelope | Shared session state | `session/contract.json` | lean-ctx knowledge recall |
| State machine | Legal transitions | `rules/rules.json` | orchestrator (enforced in prompt) |
| Scoring | PASS/RETRY/BLOCKED | `rules/rules.json` | orchestrator (scoring pipeline) |
| Agents | Role definitions | `opencode.json` + `agents/*.md` | OpenCode at startup |
| Skills | Extensible behaviors | `skills/*/SKILL.md` | On-demand via skill() tool |
| Tools | MCP capabilities | `opencode.json` mcp section | OpenCode MCP client |
| Usage guides | How-to references | `usage/*.md` | On-demand via lean-ctx read |
| Governance | Rules, constraints, safety | `agent.md §6 + rules.json` | All agents at session start |
| Contract schema | Envelope structure | `contract/contract.schema.json` | validate-contract.sh at every transition |
| Session archive | Per-session snapshots | `session/` | scripts/snapshot-contract.sh |
| Audit-observability | State tracking, score analytics | `skills/audit-observability/SKILL.md` | On-demand via skill() |

## C4. Companion Skills Registry Pattern

Meta-skills like `java-developer` act as **registries** linking to specialized companion skills. Lazy-loads domain knowledge without bloating core skill.

### How It Works

```
Agent loads /skill java-developer
       ↓
java-developer/SKILL.md contains "Companion Skills" table
       ↓
Agent sees: "Need JPA patterns? Load /skill jpa-hibernate-patterns"
       ↓
Agent loads companion skill on-demand (39-line reference stub)
       ↓
Companion skill points to canonical source (e.g., piomin/claude-ai-spring-boot)
```

### Structure

| Layer | Location | Purpose | Size |
|-------|----------|---------|------|
| **Meta-skill** | `skills/java-developer/SKILL.md` | Core patterns + companion registry table | ~467 lines |
| **Companion skill** | `skills/jpa-hibernate-patterns/SKILL.md` | Reference stub with source URL + when-to-use | ~39 lines |
| **Canonical source** | GitHub repo (external) | Full implementation guidance | Varies |

### Companion Skills (22 total, linked from java-developer)

| Category | Skills |
|----------|--------|
| **Framework** | `spring-boot-enterprise`, `spring-boot-4x`, `restart-spring-boot` |
| **Language** | `java-streams`, `java-optional`, `java-code-quality`, `java-design-patterns`, `java-logging-patterns`, `jspecify-nullability` |
| **Database** | `jpa-hibernate-patterns`, `jooq-best-practices`, `postgres-table-design`, `pgvector-search`, `postgres-text-search` |
| **Testing** | `mutation-testing`, `coverage-kover-gradle`, `ralph-coverage`, `gradle-test-runner`, `jdb-debugger` |
| **Workflow** | `commit`, `rebase-commit`, `spec` |

### Source Repositories

All companion skills reference canonical sources from [jvmskills.com](https://jvmskills.com):
- [piomin/claude-ai-spring-boot](https://github.com/piomin/claude-ai-spring-boot) — Spring Boot, JPA, code quality, design patterns, logging
- [martinfrancois/java-streams-skill](https://github.com/martinfrancois/java-streams-skill) — Streams API
- [martinfrancois/java-optionals-skill](https://github.com/martinfrancois/java-optionals-skill) — Optional patterns
- [sivaprasadreddy/sivalabs-agent-skills](https://github.com/sivaprasadreddy/sivalabs-agent-skills) — Spring Boot 4.x, JSpecify
- [timescale/pg-aiguide](https://github.com/timescale/pg-aiguide) — PostgreSQL design, pgvector, text search
- [jvm-skills/jvm-skills](https://github.com/jvm-skills/jvm-skills) — jOOQ, mutation testing, Kover, workflow skills
- [brunoborges/jdb-agentic-debugger](https://github.com/brunoborges/jdb-agentic-debugger) — JDB debugging

---

[workflow-shield]: https://img.shields.io/badge/Workflow-Orchestration-blue?style=for-the-badge
