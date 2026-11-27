<!-- omit from toc -->

# Workflow State Engine - Orchestration Toolkit

**Contract-driven state machine orchestration engine for AI agent workflows.**

State machine: `INIT → PLAN → PLAN_SCORED → EXECUTE → EXECUTE_SCORED → REVIEW → REVIEW_SCORED → COMPLETE`

Single source of truth for all AI agents. Reference skills and usage guides for depth. This file is `instructions[0]` - loaded by every agent at session start.

[![Contributors][contributors-shield]][contributors-url] [![Forks][forks-shield]][forks-url] [![Stargazers][stars-shield]][stars-url] [![Issues][issues-shield]][issues-url] [![License][license-shield]][license-url]

<a id="readme-top"></a>

## Table of Contents
1. [1. Project Overview](#1-project-overview)
2. [2. Framework Architecture](#2-framework-architecture)
3. [3. Agent Reference - 17 Agents (Scrum Team)](#3-agent-reference--17-agents-scrum-team)
4. [4. Tool Usage Reference](#4-tool-usage-reference)
5. [5. Development Workflow](#5-development-workflow)
6. [6. Non-Negotiable Rules](#6-non-negotiable-rules)
7. [7. Skills Reference](#7-skills-reference)

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## 1. Project Overview

### Core Concepts

| Concept | Description |
|---------|-------------|
| **Shared JSON Envelope** | `session/contract.json` - single source of truth for state, decisions, outputs, scoring |
| **State Machine** | 8 forward-flow states + BLOCKED escalation; agents transition through the workflow via the envelope |
| **Scoring Pipeline** | Three-tier scoring after every delegation (rule checks → LLM-as-judge → combined verdict) |
| **Agent Delegation** | Orchestrator delegates to specialized scrum-team agents (product-manager, system-analyst, developer, devops-engineer, quality-analyst, security-engineer, scrum-master, …) |
| **Cross-Model Review** | Reviewers run on a different model than executors; conflicting verdicts → BLOCKED, arbitrated by `council` |
| **Cross-Session Learning** | Lessons, patterns, gotchas persisted via `ctx_knowledge` |

### State Machine Transitions

```
INIT → PLAN → PLAN_SCORED → EXECUTE → EXECUTE_SCORED → REVIEW → REVIEW_SCORED → COMPLETE
                              ↘                ↘                ↘
                          BLOCKED (score < 50 or retry ≥ 3)
                                ↘
                          User intervention → retry with guidance
```

| Transition | Gate | Condition |
|-----------|------|-----------|
| INIT → PLAN | Session created | Always |
| PLAN → PLAN_SCORED | Plan produced | Always |
| PLAN_SCORED → EXECUTE | Plan accepted | Score ≥ 70 |
| EXECUTE → EXECUTE_SCORED | Implementation done | Always |
| EXECUTE_SCORED → REVIEW | Code review | Score ≥ 70 |
| REVIEW → REVIEW_SCORED | Review done | Always |
| REVIEW_SCORED → COMPLETE | All gates pass | Score ≥ 70 |
| Any → BLOCKED | Escalation | Score < 50 or retry ≥ 3 |

### Scoring Pipeline (Three-Tier)

1. **Tier 1 - Rule-Based Checks**: Schema valid (-15), permissions violated (-40), blast radius HIGH (-40), writing order wrong (-15), over-engineering (-15), required fields missing (-15). Subtotal ≥ 70 → Tier 2.
2. **Tier 2 - LLM-as-Judge**: Scores 0-100 on requirements fulfillment (0-40), governance compliance (0-30), completeness (0-20), edge cases (0-10).
3. **Tier 3 - Combined Verdict**: PASS (≥70), RETRY (50-69, max 3 attempts), BLOCKED (<50).
4. **Scores Ledger**: each scoring run appends a JSONL line (timestamp, phase, combined, verdict) to scores.jsonl beside the contract (auto-score.sh --phase).
5. **Persist the ledger (MANDATORY)** - after every delegation and scoring, run:
   `lean-ctx ctx_shell /opt/engine/scripts/auto-score.sh --file session/contract.json --rules /opt/engine/rules/rules.json --phase <PHASE>`
   This appends one JSONL line (timestamp, phase, combined, verdict, task, agent, model, commit) to `session/scores.jsonl`. A scoring phase with no ledger line is **not complete**; `scripts/state-guard.sh` warns when the ledger is absent past `PLAN_SCORED`.
6. **Judge coverage (MANDATORY)** - before REVIEW and COMPLETE, run `lean-ctx ctx_shell /opt/engine/scripts/judge-coverage.sh session/scores.jsonl`; record the result under `governance.judge_coverage`. `coverage_pct = 0` means no phase had independent judge evidence - report it explicitly and never present a `tier1_only` score as judge-backed.
7. **Typed failure loop** - on a RETRY verdict, run `scripts/failure-loop.sh --type CLASS --attempt N --max M --hash H --last-hash LH` (classes: compile, convention, malformed, model-drift, security, test, review, gate, timeout/flaky). It returns one strategy mechanically: RETRY_WITH_GUIDANCE (0), CHANGE_APPROACH (2), ESCALATE (3), BLOCKED (4). Never re-run an identical attempt hash. The verdict corpus `scripts/eval-tasks/T4-score-calibration.sh` checks boundary scores and false-PASS/false-BLOCK drift; `scripts/eval-tasks/T9-judge-agreement.sh` checks verdict aggregation and jitter stability on a labeled fixture corpus; it does not measure agreement between real model judges (see `doc/efficiency-limits.md`).


**Tier 1 checks** (start at 100, deduct per violation):

| Check | Method | Deduction |
|-------|--------|-----------|
| Schema valid | Parse output against expected structure | -15 |
| Permissions violated | Forbidden anti-patterns (conventions violations, FQN, edits outside scope) | -40 |
| Blast radius safe | `ctx_impact` on changed symbols | -40 if HIGH/CRITICAL |
| Writing order correct | Verify port->service->mapper->adapter order in plan | -15 |
| Over-engineering safe | No speculative abstractions beyond plan scope | -15 |
| Required fields present | Check expected keys are non-null in output | -15 |

### Architecture

```
agents/     → 17 agent instruction files (orchestrator, product-manager, scrum-master, developer, devops-engineer, quality-analyst, security-engineer, …)
skills/     → 46 skill directories (system-analyst, writing-plans, spec-driven-development, …)
commands/   → slash commands (impeccable)
contract/   → contract.template.json, contract.schema.json, state.template.md
rules/      → rules.json (state machine transitions, scoring thresholds, cross-model review)
doc/        → workflow guides, project.md, gap analysis, reports
```

<p align="right">(<a href="#readme-top">back to top</a>)</p>

---

## 2. Framework Architecture

### Deployment Layout

The engine ships inside the container image (`COPY engine/ /opt/engine/`) and is exposed to OpenCode through symlinks in the config directory. Agents read it at `/opt/engine/`:

```
~/.config/opencode/
   ├── opencode.json → (bind-mounted) config/opencode.json
   ├── agent.md   → /opt/engine/agent.md      (instructions[0])
   ├── agents/    → /opt/engine/agents/        17 agent instruction files
   ├── skills/    → /opt/engine/skills/        46 skill directories
   ├── commands/  → /opt/engine/commands/      slash commands
   ├── rules/     → /opt/engine/rules/         rules.json (state machine)
   ├── contract/  → /opt/engine/contract/      contract.template.json, contract.schema.json, state.template.md
   ├── usage/     → /opt/engine/usage/         4 tool usage guides
   └── doc/       → /opt/engine/doc/           workflow guides, reports
```

Engine changes take effect on container rebuild; the bind-mounted config on restart.

### Directory Tree

The `engine/` source mirrors the runtime layout - edit here, rebuild to deploy:

```
├── agent.md           ← THIS FILE (instructions[0]; includes the §lean-ctx code-intelligence block)
├── README.md          ← Project overview (diagram, badges)
├── /opt/engine/agents/            ← 17 agent instruction files
├── /opt/engine/doc/               ← Workflow guides, project.md, reports
├── /opt/engine/rules/             ← rules.json (state machine, scoring, cross-model review)
├── /opt/engine/skills/            ← 46 skill directories
├── /opt/engine/commands/          ← slash commands
├── /opt/engine/contract/          ← contract.template.json, contract.schema.json, state.template.md
├── /opt/engine/usage/             ← 4 tool usage guides
└── /opt/engine/scripts/           ← Automation & validation scripts
```

<p align="right">(<a href="#readme-top">back to top</a>)</p>

---

## 3. Agent Reference - 17 Agents (Scrum Team)

> Full agent instruction files at `/opt/engine/agents/` (symlinked into the OpenCode config dir). Each file defines role, MCPs, skills, and post-flight protocol.
>
<!-- SINGLE SOURCE OF TRUTH for model IDs: engine/models.json. Mirrors must match; enforced by scripts/check-model-config-drift.sh -->
> **Model tiers**: `executor` = `sumopod/glm-5.3-flash` (build/plan tier - developer, fixer, system-analyst); `default` = `sumopod/glm-5.3-flash` (all other agents); `light` = `sumopod/hy4-flash` (explorer, librarian, explore subagent - fast lookup loops; also the executor fallback); reviewers (`quality-analyst`, `security-engineer`, `software-architect`) pinned to `opencode/deepseek-v4.1-flash-free`. Reviewers never share the executor's model - this is the basis of **cross-model review**.

### Orchestrator

| Agent | Role | Key MCPs | Access | Contract States | Model | Skills | File |
|-------|------|----------|--------|----------------|-------|--------|------|
| **orchestrator** | Scrum lead / primary orchestrator - delegates, scores, drives the state machine | lean-ctx, context7 | Read/write (lean-ctx only) | `*` (all) | default | (orchestrator - agent.md) | `/opt/engine/agents/orchestrator.md` |
| **design-orchestrator** | UI/UX specialist orchestrator - enforces 4-layer design pipeline (Exemplar > Generator > Taste > Gate) | lean-ctx, context7 | Read/write (lean-ctx only) | `*` (all) | default | design-exemplar, ui-ux-pro-max, design-taste-frontend, impeccable, banner-design, brand, slides, ui-styling | `/opt/engine/agents/design-orchestrator.md` |

### Bootstrap Agent (primary entrypoint)

| Agent | Role | Key MCPs | Access | Contract States | Model | Skills | File |
| **build** | Restricted bootstrap/interactive entrypoint (mode: primary) - no file or shell access, hands tasks to the orchestrator | lean-ctx | Restricted (frontmatter deny-all; `.env` read ask/allow) | n/a (primary) | executor | (none) | `/opt/engine/agents/build.md` |

### Product & Planning Agents (read-only)

| Agent | Role | Key MCPs | Access | Contract States | Model | Skills | File |
|-------|------|----------|--------|----------------|-------|--------|------|
| **product-manager** | Requirements + acceptance-criteria backlog (GWT) | lean-ctx, context7 | Read-only | `INIT`, `PLAN` | default | business-analyst, brainstorming, writing-plans, diagram-design | `/opt/engine/agents/product-manager.md` |
| **system-analyst** | Impact analysis, specs, detailed plans | lean-ctx, cocoindex-code | Read-only | `INIT`, `PLAN`, `PLAN_SCORED` | executor | system-analyst, business-analyst, writing-plans, diagram-design | `/opt/engine/agents/system-analyst.md` |
| **software-architect** | Architecture trade-offs, tech-debt assessment | lean-ctx, cocoindex-code | Read-only | `INIT`, `PLAN`, `PLAN_SCORED`, `REVIEW` | opencode/deepseek-v4.1-flash-free | system-analyst, java-developer, diagram-design | `/opt/engine/agents/software-architect.md` |

### Implementation Agents (read/write)

| Agent | Role | Key MCPs | Access | Contract States | Model | Skills | File |
|-------|------|----------|--------|----------------|-------|--------|------|
| **developer** | Implements the plan, writes tests alongside code | lean-ctx, cocoindex-code | Read/write (lean-ctx only) | `EXECUTE`, `EXECUTE_SCORED` | executor | test-driven-development, software-developer, design-taste-frontend, impeccable, awesome-pr, tool-economy | `/opt/engine/agents/developer.md` |
| **devops-engineer** | CI/CD, containerization, deploy, migrations, observability, rollback | lean-ctx | Read/write (lean-ctx only) | `EXECUTE`, `EXECUTE_SCORED`, `REVIEW` | default | devops-expert, observability-and-instrumentation, diagram-design | `/opt/engine/agents/devops-engineer.md` |
| **fixer** | Bounded, scoped fixes for well-defined tasks | lean-ctx | Read/write (lean-ctx only) | `EXECUTE` | executor | systematic-debugging | `/opt/engine/agents/fixer.md` |

### Quality & Process Agents (read-only)

| Agent | Role | Key MCPs | Access | Contract States | Model | Skills | File |
|-------|------|----------|--------|----------------|-------|--------|------|
| **quality-analyst** | Independent quality review (5-axis: correctness, readability, architecture, security, performance) | lean-ctx, cocoindex-code | Read-only | `REVIEW`, `REVIEW_SCORED` | default | qa-expert, security-expert, code-review-and-quality, impeccable | `/opt/engine/agents/quality-analyst.md` |
| **security-engineer** | Independent security review - threat model, vulns, secrets, trust boundaries | lean-ctx | Read-only | `REVIEW`, `REVIEW_SCORED` | default | security-expert, code-review-and-quality | `/opt/engine/agents/security-engineer.md` |
| **scrum-master** | Process owner - guards the contract, state machine, and workflow; unblocks BLOCKED, DoD gate | lean-ctx | Read-only | `*` (all), `BLOCKED` | default | orchestration-template, audit-observability, adaptive-solver | `/opt/engine/agents/scrum-master.md` |
| **learner** | Post-execution retro - extract lessons, gotchas, patterns | lean-ctx | Read-only | `REVIEW_SCORED`, `COMPLETE` | default | verification-before-completion | `/opt/engine/agents/learner.md` |

### Support Agents (read-only)

| Agent | Role | Key MCPs | Access | Contract States | Model | Skills | File |
|-------|------|----------|--------|----------------|-------|--------|------|
| **explorer** | Fast codebase search / unknowns discovery | lean-ctx, cocoindex-code | Read-only | `*` (all) | default | (exploration) | `/opt/engine/agents/explorer.md` |
| **librarian** | External docs / library research | context7, cocoindex-code | Read-only | `*` (all) | default | (research) | `/opt/engine/agents/librarian.md` |
| **council** | Multi-model consensus + cross-model arbitration | lean-ctx | Read-only | `*` (all) | default | (multi-LLM consensus) | `/opt/engine/agents/council.md` |
| **observer** | Visual analysis - images, PDFs, diagrams | lean-ctx | Read-only | `*` (all) | default | (visual analysis), impeccable, diagram-design | `/opt/engine/agents/observer.md` |

### Lane Name Mapping
| Lane | Agent | subagent_type |
|------|-------|---------------|
| `@product-manager` | product-manager | `product-manager` |
| `@scrum-master` | scrum-master | `scrum-master` |
| `@devops-engineer` | devops-engineer | `devops-engineer` |
| `@security-engineer` | security-engineer | `security-engineer` |
| `@explorer` | explorer | `explorer` |
| `@librarian` | librarian | `librarian` |
| `@fixer` | fixer | `fixer` |
| `@council` | council | `council` |
| `@observer` | observer | `observer` |
| `@system-analyst` | system-analyst | `system-analyst` |
| `@developer` | developer | `developer` |
| `@quality-analyst` | quality-analyst | `quality-analyst` |
| `@learner` | learner | `learner` |
| `@software-architect` | software-architect | `software-architect` |
| `@design-orchestrator` | design-orchestrator | `design-orchestrator` |
| (entrypoint) | build | n/a (mode: primary) |

### Agent State Machine

See [`/opt/engine/doc/workflow.md`](/opt/engine/doc/workflow.md) for the canonical state machine, scoring pipeline, gates, and validation rules.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

---

## 4. Tool Usage Reference


### 4.1 Quick Reference

| Tool | What It Does | Guide |
|------|-------------|-------|
| **lean-ctx** | File reads, shell, search, edit, impact analysis, knowledge persistence, sessions | `/opt/engine/usage/lean-ctx.md` |
| **Context7** | Library/framework docs lookup | `/opt/engine/usage/context7.md` |
| **rag MCP** (`rag_search` / `rag_index` / `rag_status` / `rag_get`) | Semantic search over workspace code, docs, and engine skills before unfamiliar work | `/home/node/workspace/agents/opencode/rag/README.md` |
| **Firecrawl plugin** | First-party V2 plugin: keyless developer search, keyed alexandria gated to ask, CLI skills registered at runtime | `/opt/engine/plugins/opencode-firecrawl/VENDORED.md` |

### 4.3 Tool Comparison Matrix

| Task | Best Tool | Why |
|------|-----------|-----|
| **Check blast radius before editing** | `ctx_impact` | Knowledge graph tracks callers/importers at d=1/d=2/d=3 depths |
| **Explore unfamiliar code flows** | `ctx_compose` | Returns process-grouped execution flows ranked by relevance |
| **AST-aware semantic code search** | cocoindex-code MCP (`ccc` CLI) | AST-semantic index across the workspace; complements lean-ctx, never a symbol/callgraph replacement |
| **Read/edit files** | `lean-ctx ctx_read`/`ctx_edit` | Cached reads (~13 tok), safe search-and-replace edits |
| **Shell commands** | `lean-ctx ctx_shell` | Compressed output, 95+ patterns, replaces bash |
| **Persist decisions/knowledge** | `lean-ctx ctx_knowledge remember` | Cross-session persistence with embeddings |
| **Save/resume sessions** | `lean-ctx ctx_session` | Survives OpenCode restarts |
| **External library research** | `context7_query_docs` | Official docs lookups with code examples |
| **Primary-source passages (issues, PRs, READMEs)** | `firecrawl_developer_search` | Keyless plugin search over raw sources; best for error hunting and API contract questions |
| **Single arbitrary page** | fetch MCP (`fetch`) | Keyless one-off HTTP GET; zero-dependency fallback |
| **Multi-model consensus** | `@council` subagent | Fresh-context adversarial review for high-stakes decisions |

### 4.4 Retrieval Balance (rag MCP)

`rag_search` over the workspace index is advisory, not a gate. Use it when entering an unfamiliar area, discovering project conventions, surveying existing implementations before writing code, or answering questions that span workspace code and docs. Skip it when the file is already in context, when `ctx_search` answers an exact-symbol lookup, or when the edit is trivial.

Guardrails:

1. Snippets are discovery anchors: open the cited file region with `ctx_read` before editing or quoting it as fact.
2. Stale index: if files changed since the last index, run `rag_index` first (incremental, hash-based, cheap).
3. Empty or weak hits: say so and fall back to `ctx_search` and direct reads. Never present memory-filled gaps as project facts.
4. Cite hits as `path:startline` so humans can verify.
5. Skip the search when the answer is already in context or you hold the exact file; `rag_search` is for discovery across the workspace, not for reading a known file.

Index scope: `/home/node/workspace`, built automatically at session boot when the server starts; run `rag_index` after bulk changes.

### 4.5 Retrieval Routing - ask the right layer once

Every retrieval question has exactly one right tool. Query the wrong layer and you pay an inference round-trip for nothing.

| Question type | Tool (1 call) | Never do |
|------|------|------|
| Exact symbol, callers, blast radius | `ctx_search` symbol / `ctx_impact` | grep sweeps across files |
| "How does our code do X" | `rag_search` | opening many files to re-derive |
| AST-aware semantic code search, cross-repo | `ccc` CLI / cocoindex-code MCP | not for impact/callgraph (lean-ctx) or docs (rag) |
| Library / framework API | `context7` | guessing from memory, random web search |
| Errors, issues, PR discussions | `firecrawl_developer_search` | broad web search |
| Single known page | `fetch` | scrape-first patterns |
| Past decisions, conventions, lessons | `ctx_knowledge recall` | re-deriving from scratch |

Scope `rag_search` with `glob` (e.g. `agents/opencode/engine/**`) before widening the query. Run `rag_index` after bulk edits - it is incremental and hash-based.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

---

### 4.6 Tool Ownership

One owner per capability; agents must use the designated tool, not a parallel path:

| Capability | Owner | Notes |
|---|---|---|
| Repo reads, search, shell | lean-ctx (`ctx_read`/`ctx_search`/`ctx_shell`) | Mandatory access layer; native read/bash bypass = governance violation |
| Library / framework docs | context7 | Official docs lookup; never guess from memory |
| Semantic workspace search | rag (`rag_search`) | Discovery across the workspace; verify hits before editing |
| AST semantic code index | cocoindex-code MCP | complements lean-ctx; not a symbol/callgraph replacement |
| Single known page | fetch | Keyless one-off HTTP GET |
| Broad web search | websearch | Current events beyond library docs |
| Issues / PRs / READMEs | firecrawl_developer_search | Primary-source passages, keyless |
| Gated data providers | firecrawl_alexandria | `ask` permission; needs user confirmation |
| UI generation | openui | Live UI rendering |
| Subagent dispatch | task | One owner for spawning work |


## 5. Development Workflow

### Tier Routing (read first)

Classify every task before any ceremony starts. The classification is a
single decision the orchestrator makes and records in the session notes;
it is never re-derived per phase.

| Tier | Shape | Ceremony |
| ---- | ----- | -------- |
| T1 Direct | 1-2 files, git-revertible, unambiguous scope | Inline execution: edit, run gates, commit. No state machine, no envelope, no delegation. Budget: about 10 turns. |
| T2 Light | 3-10 files, parallelizable, clear scope | One full-context delegation plus verification. session/state.md notes suffice; contract.json optional. Budget: about 20 turns. |
| T3 Full | ambiguous scope, multi-service, security-sensitive, or an audit on request | The full flow: envelope, analysts, developer, cross-model review, scoring pipeline. |

Rules:

- The state machine and the scoring pipeline exist for T3. Running T1 or T2 work through T3 ceremony is not discipline; it is waste.
- Minimum gates are never skipped at any tier: the repo check scripts or loop-validate runs before every ship. Production gates apply by task class (see task classes below).
- When the tier is unclear, classify one level lower, T3 becomes T2 and T2 becomes T1, and raise it only when the work proves bigger.
- Security-sensitive changes are always T3.

**Task class (recorded in `session.task_class`):** `trivial` (docs/typo, direct), `standard` (one-file fix, single implement-review loop), `cross-service` (multi-file feature, full graph with spec), `security-critical` (full graph, independent security review + council), `prototype` (explicit prototype mode: minimum gates only, no production orchestration). Full orchestration applies only to `standard` and higher. Two gate levels: minimum gates (repo check scripts or loop-validate before every ship) run for every tier and class, prototype included; production gates (spec gate, cross-model review, scoring pipeline) apply only to `standard` and higher.

### Phase Telemetry

Measure efficiency instead of asserting it. Before each phase run `scripts/phase-telemetry.sh start --phase NAME` (it prints a `run_id`); after the phase run `scripts/phase-telemetry.sh stop --run-id ID --tokens-in N --tokens-out N --verdict V` (token figures are caller-supplied estimates, not provider measurements). `scripts/phase-telemetry.sh report` aggregates wall-clock and token totals by phase and task class from completed runs only; `active` lists open runs. Record the summary under `metrics.phase_durations` before COMPLETE. Malformed ledger rows and orphaned starts never count as completed work. `scripts/phase-telemetry.sh coverage --class C --task ID` checks that every phase required by the task class has a completed start/stop pair and exits nonzero when one is missing. Learning reuse is tracked with `scripts/learning-record.sh hit --key K --source-task T` and summarized by `impact`. See `doc/efficiency-limits.md` for what is enforced locally versus what needs production data: token counts are caller-supplied, telemetry calls are instruction-driven, judge agreement is aggregation-level, and no production dataset proves lighter classes are cheaper.



### Session Model

Work is tracked in a single `session/` directory - no git branches required.

- All contract state lives in `session/contract.json`; snapshots are archived in `session/`.
- The engine is repository-agnostic - never block on branch or VCS checks.
- Every session is self-contained and resumable from `session/`.

Git stores source code; the workflow never assumes a VCS - services arrive with their own patterns.
Users connect and prepare their own repositories and tell the agent what to do; sandbox/ is the user playground.

### Before Any Edit

```
1. ctx_read / ctx_compose - understand the code first
2. ctx_impact({target: "symbol", direction: "upstream"})   # blast radius
3. If HIGH/CRITICAL → warn user before proceeding
```


Run this ladder in order before writing ANY code:

```
1. Does this need to exist?       → skip it (YAGNI)
2. Standard library does it?      → use it
3. Native platform feature?       → use it
4. Already-installed dependency?  → use it
5. Can this be one line?          → one line
6. Only then: minimum code that works
```


**Not sacrificed:** Input validation at trust boundaries, data-loss error handling, security, accessibility, anything explicitly requested. Non-trivial logic leaves ONE runnable check (assert-based, no framework).

### Shared Protocol (binding on every agent)

Every agent instruction file carries a short pointer to `engine/shared/protocol.md`. Read that file at session start: it holds the canonical envelope-recall syntax, access policy, persistence rules, and post-flight steps. `scripts/prompt-budget.sh` measures character duplication across `engine/agents/*.md` and fails when it exceeds `PROMPT_DUP_MAX` (default 20%) or any agent lacks the pointer. Expanding a repeated block inline instead of referencing the shared protocol is a budget violation.

### Session Start: Memory Bootstrap (MANDATORY before any work)

Every agent runs this step at session start, before Context Load, planning, or edits. Recall is an MCP tool call, **never** a shell command (`lean-ctx knowledge` shell calls are policy-blocked for agents).

1. **Load the orchestration envelope**: `ctx_knowledge recall key="orchestration-contract:<task_id>" mode="exact"`.
   - Empty → create fresh from `contract/contract.template.json`, set `state=INIT`.
   - Found → resume from `state`, `retry.issues[]`, `decisions`, `governance`.
2. **Recall prior lessons**: `ctx_knowledge recall --query "lessons" --mode semantic`.
   - On hits, copy the relevant ones into `governance.current_guidance`; dedupe against `lessons_learned[]`.
   - Empty on a first session → proceed normally.
3. **Record the receipt** in the envelope before the first delegation:
   ```json
   "memory_bootstrap": { "at": "<ISO-8601>", "contract_recalled": true, "lessons_found": 0 }
   ```
4. **No delegation or edits without this receipt.** `scripts/state-guard.sh` emits a visible WARN when it is absent in any state past `INIT`.

Why: knowledge writes are cheap and frequent; without a mandatory recall step they are never consumed, so the Learn layer degrades into write-only logging.

### Orchestration Flow (Scrum Team - Spec-Driven Development)

This is the T3 ceremony. T2 tasks run the verify loop and the humanizer gate; T1 runs the verify gates only, and the humanizer gate only when user-facing text ships.

1. **Refine phase** - Delegate to @product-manager: capture intent, write Given-When-Then acceptance criteria, declare scope + non-goals. Attach user-journey or story-map diagrams via diagram-design when intent spans multiple actors.
2. **Discuss phase** - 5-lens check: Business, System, Dev, QA, DevOps. Clarify requirements.
  - **Domain context (advisory)**: `rag_search` supplies domain context when the request touches unfamiliar code or docs.
3. **Plan phase** - Delegate to @system-analyst: impact analysis, edge cases, implementation plan. @software-architect reviews the plan (independent model). Plans spanning >3 files or crossing services include an architecture/impact diagram (diagram-design).
4. **Spec gate** (if >3 files, cross-service, or >30 min) - Gate check: `lean-ctx ctx_shell /opt/engine/scripts/sdd-gate.sh --file session/contract.json || STOP` - Write GWT-format specs. Cross-examine via DDD.
5. **Execute phase** - Delegate to @developer: implement plan step by step, write tests alongside code. @devops-engineer owns pipeline/deploy/migration. @fixer for scoped fixes. UI tasks load design-taste-frontend; developer passes the impeccable detector before marking UI work done (EXECUTE exit gate). Advisory retrieval: the developer consults `rag_search` for project conventions before writing non-trivial code, then verifies hits against the file before editing.
  - **Context gate**: @developer loads project standards via `/skill context-standards` before edits when the target project defines `context/` files; @quality-analyst verifies compliance during review.
6. **Review phase** - Delegate to @quality-analyst (5-axis) AND @security-engineer (security) on the **reviewer model**, independent from the executor. Conflicting verdicts → BLOCKED, arbitrated by @council. UI diffs get the impeccable design-lens (slop detector) inside the readability axis.
7. **Process gate** - @scrum-master audits transitions, enforces gates, and owns the Definition of Done before COMPLETE. Unblocks BLOCKED sessions.
**Parallel merge transaction** - when `scope.parallel_eligible` is true, each developer owns a file-disjoint shard. Build a manifest (`[{name, dir, files:[relative paths]}]`) and run `scripts/merge-shards.sh --manifest FILE --target DIR --report FILE`. It aborts before touching any target file on duplicate paths, absolute/`..` paths, missing shard dirs, or missing sources, and rolls back already-applied files if a copy fails. Use `--dry-run` to preview. Two agents touching the same file means conflict: re-delegate serially rather than merging. The merge is crash-safe: files are staged and applied by atomic rename under a persistent journal; an `EXIT`/`INT`/`TERM` trap rolls back applied files, and `merge-shards.sh --recover --target DIR` restores after an abrupt termination.

**BLOCKED SLA** - `transition.sh` stamps `retry.blocked_at` and appends an `escalation_trace` entry on entry to BLOCKED, and clears the clock on a user-override exit. `scripts/blocked-sla.sh check` reports `within_sla` or `sla_breached` (exit 1) against `rules.json -> state_machine.blocked_ttl_hours` (default 24h); `scripts/blocked-sla.sh sweep --dir PATH` checks every `contract.json` under a directory for health/cron use. A breached SLA requires escalation to the user and @scrum-master before any retry. The check is advisory and operator-driven: no scheduler invokes the sweep automatically, so a session that is never checked can exceed the TTL silently.

8. **Verify loop** - Run build commands, check conventions. Executors and fixers run `scripts/loop-validate.sh` as the inline done-gate before REVIEW.
9. **Ship** - COMPLETE gate: `lean-ctx ctx_shell /opt/engine/scripts/verify-knowledge.sh --all || STOP` - Resolve issues, confirm deploy safety, run post-flight protocol; @learner captures lessons.
10. **Humanizer gate** - run `/skill humanizer` over all user-facing outputs shipped this session (READMEs, docs, PR descriptions, changelogs, release notes) before declaring COMPLETE. Docs that still carry AI patterns (em dashes, rule-of-three, promotional tone) are not done. Mandatory for user-facing text outputs; internal state files (session/state.md, contract JSON, code comments) are exempt.

### UI/UX Pipeline (Mandatory)

All UI work runs the 4-layer pipeline in this order - enforced by @design-orchestrator:

| # | Layer | Skill | Role |
|---|-------|-------|------|
| 1 | Exemplar | `design-exemplar` | Copy a proven look from the 84-brand DESIGN.md library (Linear, Stripe, Vercel, …) when a reference brand is named |
| 2 | Generator | `ui-ux-pro-max` | BM25-search a fitting design system (styles, palettes, fonts, patterns) for the user's own product |
| 3 | Taste | `design-taste-frontend` | Art direction pass - kill generic "AI-slop" patterns, enforce gallery-grade composition |
| 4 | Gate | `impeccable` | No UI task is done without an impeccable design-lens review |

Layer selection: user names a reference brand → Exemplar; user describes their own product → Generator; neither → Generator; trivial tweak (<10 lines, no new components) → pipeline may be skipped, impeccable gate still applies.

Rules: order is mandatory; never mix Exemplar + Generator for the same page; DESIGN.md (page) / MASTER.md (global) persistence per ui-ux-pro-max `--persist`.

Use **Doubt-Driven Development (DDD)** when uncertain: spawn a fresh-context adversarial reviewer to cross-examine non-trivial decisions before they stand.

### Guard Plugin Registration

Verify with `scripts/check-plugin-registration.sh`: the guard plugin path must be present in the live OpenCode config, and `guard.js`, `index.js`, and `package.json` must exist and parse. Agents never edit `~/.config/opencode/opencode.json` directly; config changes go through the normal sync and restart path. A `not_registered` result means the hooks are inert and every controller gate is advisory until the config is synced. The check is configuration-level: it proves the path and file integrity, not that a running OpenCode process loaded the hook or that tool events reach the controller.

### Before Commit (Post-Flight Protocol)


**Pre-flight**: `lean-ctx ctx_shell /opt/engine/scripts/validate-contract.sh --file session/contract.json --score` (score < 70 = BLOCKED)
**Parallel conflict check**: `lean-ctx ctx_shell /opt/engine/scripts/detect-parallel-conflicts.sh --file1 /tmp/a.txt --file2 /tmp/b.txt`
**Atomic persist**: `lean-ctx ctx_shell /opt/engine/scripts/persist-contract.sh --file session/contract.json --inject-score 85` |

Exceptions: docs-only changes skip impact, change-detect, and re-index steps. Config-only changes skip impact and change-detect.

### Save Session Protocol

When the user says "save session" or a phase completes, run the full 8-step Post-Flight protocol; the canonical procedure lives in [doc/workflow/05-operations.md](doc/workflow/05-operations.md) (section E1, Save Session Protocol). Partial saves lose audit trail, break resumption, or leave stale indexes. Save to ALL systems every time.

> **LOCAL-ONLY:** `session/`, `.session/` and everything inside them are runtime state - NEVER `git add`, commit, or push them (gitignored; history grows unbounded). Archive historical state logs to `.session/` instead.

### Update All States

After major changes (merged work or resumed sessions), synchronize all state systems:

```bash

# 3. Snapshot contract state (session/ → archive)
lean-ctx ctx_shell /opt/engine/scripts/snapshot-contract.sh

# 4. Save conversation context (survives OpenCode restart)
lean-ctx ctx_session save
```


### Context Provenance

When context is retrieved for a task, record it with `scripts/context-provenance.sh record --source PATH --status verified|observed-once|unverified --tool NAME`. Capture is agent-invoked by design; no automatic retrieval hook exists. Each record ties the source path to the resolved commit, retrieval timestamp, and evidence status. Run `validate --source PATH` before citing a snippet as verified, and `report` to audit coverage and stale sources. Authority per field: `contract.json` is active task state; Lean-ctx holds derived memory; `state.md` is the append-only audit summary; source files and tests are implementation truth.

### Learning Records (evidence + decay)

Persist durable lessons with `scripts/learning-record.sh write --key K --claim TEXT --evidence CSV --verified-by NAME --ttl-days N --source-task T`. Evidence uses `file:`, `test:`, `pr:`, `commit:`, or `review:` prefixes; file and test references must resolve, unknown kinds are rejected, and a stable `key` updates an existing record instead of appending a duplicate. Records carry a verifying agent and an `expires_at` TTL; write failures exit nonzero. Before a new session assembles `governance.current_guidance`, run `scripts/learning-record.sh active` to keep only verified, unexpired records; `scripts/learning-record.sh audit` reports total/verified/expired/unverified counts. Unverified or stale lessons are excluded from guidance.

### Session Lifecycle Protocol

Every orchestration session persists contract state to the `session/` directory for cross-session traceability and safe resumption.
> **LOCAL-ONLY:** `session/`, `.session/` and everything inside them are runtime state - NEVER `git add`, commit, or push them (gitignored; history grows unbounded). Archive historical state logs to `.session/` instead.


#### Directory Layout

```
session/
├── contract.json         ← Live orchestration contract (single source of truth)
├── contract.schema.json  ← Schema for the contract
├── state.md              ← Append-only chronological state log (LOCAL-ONLY, gitignored)
└── archive/              ← Timestamped snapshots (audit trail)
```

#### Lifecycle Protocol

| Event | Action |
|-------|--------|
| **State transition** | Update `session/contract.json` → snapshot via `/opt/engine/scripts/snapshot-contract.sh` |
| **Session end** (COMPLETE/BLOCKED) | Final snapshot → append summary to `session/state.md` |
| **New session** | Re-scaffold `session/contract.json` from `/opt/engine/contract/contract.template.json` |

#### Snapshot Command Reference

```bash
/opt/engine/scripts/snapshot-contract.sh                # Full snapshot: copy files + update state.md
/opt/engine/scripts/snapshot-contract.sh --snapshot-only  # Copy files only (skip state.md updates)
/opt/engine/scripts/snapshot-contract.sh --summary "State: ${STATE} - description"  # Custom entry
/opt/engine/scripts/snapshot-contract.sh --dry-run --verbose  # Preview without changes
```

#### Why It Matters

The `session/` archive preserves:
- **Audit trail**: `session/state.md` grows monotonically - every state transition, every decision, every blocker
- **Safe resume**: `session/contract.json` is the exact state from last session - no reconstruction needed

#### Project jail: session/state.md may be unwritable

When the lean-ctx project root is the engine deployment root (/opt/engine), appending to a workspace session/state.md is refused with "path is outside the lean-ctx project jail; no further attempts made there". The refusal is terminal: do not retry it in the same session. The durable record is the contract envelope in ctx_knowledge plus the ctx_session save; the state.md sync is best-effort decoration and its absence never blocks a state transition.

### Complex Tasks (Orchestration Template)

See [orchestration-template skill](/opt/engine/skills/orchestration-template/SKILL.md) and [`/opt/engine/doc/workflow.md`](/opt/engine/doc/workflow.md) for the full orchestration protocol.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

---

## 6. Non-Negotiable Rules

- **Never commit secrets, credentials, tokens, `.env` files**

### Cross-Model Review
- **Reviewers (pinned to `opencode/deepseek-v4.1-flash-free`) must run on a different model than the executor (build/plan tier)** they audit; fallbacks must not collapse separation - on double-fallback set `governance.cross_model_degraded` and cap verdict at RETRY.
- **Conflicting reviewer verdicts** (PASS vs BLOCK) → `BLOCKED`, arbitrated by `@council` (see `rules.json → enforcement.cross_model_review`)
- **Security-sensitive changes** (auth, secrets, credentials, config, crypto) auto-require `@security-engineer` review

### Controller guards (C3/C4/C5)

- **Loop guard (C3)**: `workflow-controller.sh pre_delegation` calls `scripts/loop-guard.sh` automatically before every delegated agent call, bounded by `enforcement.loop_guard.max_loop_iterations`; exit 2 means changed approach required and exit 3 means state=BLOCKED. The orchestrator also runs the guard explicitly after every *_SCORED verdict.
- **Checkpoint (C4)**: the orchestrator runs `scripts/checkpoint.sh --contract session/contract.json` before every delegation; warn (exit 1) runs the Save Session Protocol immediately; critical (exit 2) persists and hands off to a fresh session that resumes from session/contract.json alone.
- **Memory policy (C5)**: every ctx_knowledge write passes `scripts/knowledge-gate.sh write --category C --key K --source-task T --tag verified|observed-once|dead_end --rationale R` first; exit 0 proceeds with remember; exit 2 updates the existing entry instead of inserting; exit 3 compacts the category first (archive oldest). Contamination rule: tag=dead_end entries are excluded from governance.current_guidance assembly.

### Central WorkflowPolicy Controller (C6)

State mutation is centralized: **only** `scripts/transition.sh --to STATE --agent NAME --evidence ID` may change `contract.state`. It takes an exclusive `flock`, validates the edge through `scripts/workflow-controller.sh` (reusing `state-guard.sh --to`), calls `pre_completion` on the COMPLETE edge, writes atomically, and emits immutable `pre_transition`/`post_transition` events to `session/workflow-audit.jsonl`.

Controller operations (each appends a fail-closed audit event):
- `pre_tool_action` / `post_tool_action` - called before/after `edit`, `write`, `patch`. A target is required; writes to `contract.json`, `scores.jsonl`, workflow/tool audit logs, `loop-state.json`, `.env*`, `opencode.json`, and `.session/` are denied.
- `pre_delegation` / `post_delegation` - `task`/`subagent` hooks route here with a required agent identity; state-guard checks the agent is permitted.
- `pre_transition` / `post_transition` - legal edge, explicit agent identity, and evidence whose kind is permitted for the edge (`rules.json -> enforcement.phase_evidence`): scored edges require `ledger:PASS` matching the latest score row for the current task and source phase, meeting the transition's `require_score`; exits from BLOCKED require `manual:` with `governance.user_override=true`. `FROM` is resolved before evidence so manual BLOCKED exits work.
- `pre_completion` - requires the scores ledger, memory-bootstrap receipt, judge-backed REVIEW evidence, judge coverage, and a verified learning record. For PLAN/EXECUTE/REVIEW, the latest current-task ledger row must be PASS and meet that phase's `require_score`; REVIEW must also be judge-backed. Malformed ledger rows are skipped, never trusted.
- Controller entry validates the contract schema against `contract/contract.schema.json`: parseable JSON, top-level plus nested required keys, the declared top-level type of each required property, and the enum and pattern constraints the schema declares (absent values are skipped); a missing or unparseable schema fails closed. Formats and numeric ranges are unchecked (see `doc/efficiency-limits.md`). A structurally incomplete contract with a valid `state` is treated as UNKNOWN and denies all operations.

A live session (`state.md` present) with no contract fails closed. `pre_shell` / `post_shell` audit every shell command and deny write operators (`>`, `>>`, `mv`, `cp`, `tee`, `sed -i`, `jq`, `rm`, `chmod`, `chown`) against `rules.json -> enforcement.shell_policy.protected_patterns` (`contract.json`, `.env`, `opencode.json`, `.session/`, workflow/tool audit logs, `scores.jsonl`, `loop-state.json` plus configured additions). Never modify workflow evidence or `contract.state` outside the sanctioned scripts.

### Code Safety
- **Never edit without `ctx_impact`** - run impact analysis first
- **Never commit without `ctx_delta`** - verify scope
- **Never rename with find-and-replace** - use `ctx_refactor`
- **Ignore HIGH/CRITICAL impact warnings** = governance violation

### Access (Mandatory)
- **All agent tool access flows through lean-ctx, the mandatory access layer**: reads via `ctx_read`, file discovery via `ctx_glob`/`ctx_search`, shell via `ctx_shell` (which auto-routes core primitives), code context via `ctx_compose`/`ctx_context`, impact via `ctx_impact`, knowledge via `ctx_knowledge` (`remember` requires a category), sessions via `ctx_session`
- **File edits use the host's native edit tool** (lean-ctx does not handle writes); external library documentation goes through context7
- **Bypassing the lean-ctx channel with a raw execution path is a governance violation**; deviations from any of the above require an explicit reason in the agent output

### Shell Safety
- **Always use `lean-ctx ctx_shell`** - never `bash` or `snip` (both denied in permissions)
- `bash` and `snip` trigger permission prompts and block automation

### Sandbox (Playground)
- **Pre-flight before any scratch write: determine whether the current workspace is already inside a sandbox.** Walk up from the cwd looking for a sandbox root: a directory named `sandbox` carrying its marker README or gitignore. Found one: work inside it and put the session folder directly beneath it. Detection ambiguous or no repo root above the cwd: assume you are already inside a sandbox and create nothing. Run `sandbox-guard.sh check` (engine `scripts/`) before the first scratch write of a session; it decides this mechanically.
- **Session folder comes first.** Create `<sandbox-root>/<session-slug>/` before any other scratch write; slug from the OpenCode session title (`opencode optimizer` → `opencode-optimizer`); on collision append a 4-character session-ID prefix. Every scratch path derives from that folder.
- **Session isolation is absolute.** Agents run in parallel: another agent's session folder does not exist for you. No reads, no listings, no writes, no cleanup outside your own folder. Deleting another session's folder needs explicit user approval.
- **Never create a nested sandbox inside a sandbox.** The recurring failure: an agent lands inside a sandbox tree, misreads the project root, and stacks a second sandbox level under the first. A stacked double-sandbox path is corruption; flatten it only with user approval.
- All scratch work goes to `sandbox/<session-slug>/` at the project root: probes, clones, screenshots, throwaway builds, rendered tests. Not to repo paths, not to `/tmp`, not into another session's folder.
- **Write only inside your own folder. Never write at `sandbox/` root.** Only `README.md`, `.gitignore`, and `.gitkeep` live there, and only those are tracked.
- **Sandbox contents are never committed** (gitignored via the dedicated sandbox pattern). Promote anything durable to its project folder before COMPLETE.
- **No secrets, tokens, credentials, certificates, or customer data.** Bind servers to `127.0.0.1`, use ports 4100-4999, stop them before finishing.
- **Budget:** 200 MB and 7 days per session folder. Rules, naming, and prune commands: `sandbox/README.md`; machine-readable: `rules.json → enforcement.sandbox`; runtime guard: `sandbox-guard.sh` in engine `scripts/`.

### Communication
- Explain tradeoffs, not just decisions
- Admit unknowns. Be token-efficient: concise, no filler, no full-file dumps
- Return only what was asked

<p align="right">(<a href="#readme-top">back to top</a>)</p>

---


### Tool Call Economy (all agents)

Every tool call is one full LLM inference round-trip. The rules below are mandatory discipline, not style:

1. **Batch rule** - 2+ independent tool calls: issue them in ONE turn (parallel), never serialized.
2. **Chain rule** - dependent commands on the same tool: ONE call chained with `&&` (commit-push-sync-verify is one call), never one call per step.
3. **Gate-first rule** - check policy/security constraints BEFORE composing a command. A blocked command costs a full wasted inference; never retry-blind - reroute through the sanctioned path.
4. **Spawn-tax rule** - every subagent prompt carries complete context (requirements, decisions, retry issues, exact paths). Subagents start at turn 1 of real work - zero re-discovery turns.
5. **Tier rule** - execution tiers by blast radius × reversibility × ambiguity:
  - **T1 Direct** (1-2 files, git-revertible, clear scope): orchestrator executes inline - edit → check → commit → push → verify. No subagent, no ceremony. Budget ≤10 turns.
  - **T2 Light** (3-10 files, parallelizable): max ONE subagent with a full-context prompt; orchestrator verifies after. Budget ≤20 turns.
  - **T3 Full** (security-sensitive, ambiguous scope, multi-service, or user-requested audit): analyst → developer → review with all gates.
6. **Verdict rule** - mechanical decisions (score pass/fail, routing choice, risk class): single-shot, no-tools inference on the cheapest capable model. Never a tool-loop turn.

7. **lean-ctx fluency rule** - follow usage/lean-ctx.md §13 (Field Guide): descend the discovery→zoom→edit ladder, use `diff`-mode re-reads, verify exit status alongside compressed output, recover archives with `ctx_expand` - and never edit from compressed views.

8. **Exact-edit rule** - for multi-file or exact-text edits, write a JSON spec and run `python3 /opt/engine/scripts/apply-patch.py spec.json --dry-run --diff` first, then again without `--dry-run`. Never build files with printf/sed chains (`@X@`/`@Y@` placeholders, GNU sed `\050` backrefs, `>` vs `>>` truncation, trailing `,,`, 8KB printf splits). The spec is JSON, so no shell interpolation touches replacement text; all files are validated before any write, and writes are atomic.

Known platform gap: subagent spawn does not fall back automatically on provider quota errors. On quota exhaustion, re-dispatch the same task with the fallback model set explicitly.

## 7. Skills Reference

All skills at `/opt/engine/skills/` (symlinked into the OpenCode config dir). Use `/skill <name>` for deep dives. Each skill directory contains a `SKILL.md` with full guidance.

| Skill | When to Load |
|-------|-------------|
| `java-developer` | Java 21 idioms, anti-patterns, quality gates (meta-skill - see companion skills below) |
| `software-developer` | Full-stack conventions, clean code, SOLID |
| `system-analyst` | Architecture evaluation, dependency mapping |
| `business-analyst` | Requirements gathering, acceptance criteria |
| `brainstorming` | Divergent thinking for exploring solution spaces |
| `qa-expert` | Test strategy, coverage analysis, regression prevention |
| `receiving-code-review` | Act on review feedback with technical rigor |
| `requesting-code-review` | Submit code for structured review |
| `security-expert` | Vulnerability assessment, secure coding, compliance |
| `devops-expert` | CI/CD, containerization, deployment |
| `observability-and-instrumentation` | Logging, metrics, tracing, alerting, SLI/SLO (Micrometer, Prometheus) |
| `executing-plans` | Execute implementation plans step by step |
| `release-plan` | PR templates, commit conventions, release process |
| `token-optimize` | Efficient token usage, batch operations |
| `verification-before-completion` | Verify success criteria before marking complete |
| `writing-plans` | Create structured implementation plans |
| `humanizer` | Remove AI writing patterns from output |
| `doubt-driven-development` | Validate assumptions before committing to design |
| `adaptive-solver` | Meta-cognitive uncertainty resolution - structured loop for ambiguity, low confidence, or failed attempts |
| `spec-driven-development` | Write spec first, implement after |
| `subagent-driven-development` | Delegate bounded work to specialized subagents |
| `systematic-debugging` | Structured root cause analysis |
| `test-driven-development` | Red/green/refactor cycle |
| `orchestration-template` | Contract-based multi-agent orchestration |
| `audit-observability` | State contract audit trail, orchestration observability, score analytics, cross-service consistency |
| `code-review-and-quality` | Review checklists, quality metrics |
| `simplify` | Reduce complexity without changing behavior |
| `impeccable` | Design director - critique, audit, polish UI; offline slop detector; required before UI tasks are marked done |
| `design-taste-frontend` | Art direction for frontend builds - design brief, tokens, browser self-check loop |
| `diagram-design` | 45+ branded HTML/SVG diagram types (architecture, flows, ER, journeys, deployment); Mermaid/drawio/excalidraw import |
| `drawio-animation` | Animated draw.io diagrams: native flowAnimation connectors, numbered and icon-labelled nodes, animated SVG generator (infinite loop), GIF export paths (native Animated GIF export, Confluence draw.io macro, svg-to-gif / svg-to-video headless) |
| `design-exemplar` | Exemplar layer - awesome-design-md brand index (84 DESIGN.md files), fetch workflow, when to copy a reference look |
| `ui-ux-pro-max` | Generator layer - BM25 design-system search (192 industry rules, 79 styles, 192 palettes, 74 font pairings), `--design-system`, `--persist` (MASTER.md) |
| `banner-design` | Banner/hero art direction for social media, ads, web heroes (companion of ui-ux-pro-max) |
| `brand` | Brand voice, visual identity, messaging frameworks, asset consistency (companion of ui-ux-pro-max) |
| `design` | Umbrella design skill: logo generation, CIP mockups, HTML presentations, banners, icons, social photos (companion of ui-ux-pro-max) |
| `design-system` | Token architecture (primitive→semantic→component), CSS variables, component specs, slide generation (companion of ui-ux-pro-max) |
| `slides` | Strategic HTML presentations with Chart.js, design tokens, responsive layouts (companion of ui-ux-pro-max) |
| `ui-styling` | shadcn/ui + Tailwind + canvas-based UI styling, accessible components, theming (companion of ui-ux-pro-max) |
| `awesome-readme` | README/docs standard - badges, TOC, quick start, config tables, architecture notes (distilled from matiassingers/awesome-readme) |
| `awesome-pr` | Pull request authoring - Conventional Commit titles, description template, review checklist, small-PR sizing |
| `shipping-and-launch` | End-to-end release orchestration - pre-launch verification, canary rollout, rollback planning, post-deploy smoke tests |
| `lean-ctx` | LeanCTX Context Gateway - select task-relevant context, apply controls, reuse local knowledge, inspect recorded evidence |
| `context-standards` | Discover and load project-specific pattern and standards files (context/*.md) before implementation, review, or design work |
| `dispatching-parallel-agents` | Coordinating multiple sub-agents for parallel execution - file-disjoint sharding, conflict avoidance, reconciliation |
| `tool-economy` | Tool-call discipline - batching, chaining, gate-first, spawn-tax, execution tiers, single-shot verdicts; retrieval routing table (§4.5) |

*Last updated: 2026-11-09. If you modify conventions, workflows, or config, update this file.*

<p align="right">(<a href="#readme-top">back to top</a>)</p>

<!-- lean-ctx:start -->
# lean-ctx - Code Intelligence

This project is indexed by lean-ctx as **workflow-state-engine** (1675 symbols, 1666 relationships, 0 execution flows). Use the lean-ctx MCP tools to understand code, assess impact, and navigate safely.


## Always Do

- **MUST run impact analysis before editing any symbol.** Before modifying a function, class, or method, run `impact({target: "symbolName", direction: "upstream"})` and report the blast radius (direct callers, affected processes, risk level) to the user.
- **MUST run `detect_changes()` before committing** to verify your changes only affect expected symbols and execution flows. For regression review, compare against the previous snapshot..
- **MUST warn the user** if impact analysis returns HIGH or CRITICAL risk before proceeding with edits.
- When exploring unfamiliar code, use `query({query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol - callers, callees, which execution flows it participates in - use `context({name: "symbolName"})`.

## Never Do

- NEVER edit a function, class, or method without first running `impact` on it.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis.
- NEVER rename symbols with find-and-replace - use `rename` which understands the call graph.
- NEVER commit changes without running `detect_changes()` to check affected scope.

<!-- lean-ctx:end -->

[contributors-shield]: https://img.shields.io/github/contributors/RizkiRachman/workflow-state-engine?style=for-the-badge
[contributors-url]: https://github.com/RizkiRachman/workflow-state-engine/graphs/contributors
[forks-shield]: https://img.shields.io/github/forks/RizkiRachman/workflow-state-engine?style=for-the-badge
[forks-url]: https://github.com/RizkiRachman/workflow-state-engine/network/members
[stars-shield]: https://img.shields.io/github/stars/RizkiRachman/workflow-state-engine?style=for-the-badge
[stars-url]: https://github.com/RizkiRachman/workflow-state-engine/stargazers
[issues-shield]: https://img.shields.io/github/issues/RizkiRachman/workflow-state-engine?style=for-the-badge
[issues-url]: https://github.com/RizkiRachman/workflow-state-engine/issues
[license-shield]: https://img.shields.io/github/license/RizkiRachman/workflow-state-engine?style=for-the-badge
[license-url]: https://github.com/RizkiRachman/workflow-state-engine/blob/main/LICENSE
