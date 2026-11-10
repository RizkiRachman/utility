<!-- omit from toc -->

# Part E — Operations & Reference

> See [doc/workflow/README.md](../workflow/README.md) for index.

This part covers operational procedures (post-flight protocol, session lifecycle), tooling (audit observability, conventions scripts), and reference material (lean-ctx flows, JSON Schema).

## E1. Post-Flight Protocol

This 8-step protocol runs before every commit. It verifies impact, persists knowledge, archives session state, and re-indexes code intelligence. Execute all 8 steps unless exceptions apply.

| # | Step | Tool | Exceptions |
|---|---|---|---|
| 0 | Validate contract | `bash scripts/validate-contract.sh --file session/contract.json --score` | — |
| 1 | Impact verify | `ctx_impact` | Docs-only skip |
| 2 | Change detect | `ctx_delta` | Docs-only skip |
| 3 | Knowledge persist | `lean-ctx ctx_knowledge remember` | — |
| 4 | Session archive | `bash scripts/snapshot-contract.sh --snapshot-only` | — |
| 5 | Save conversation | `lean-ctx ctx_session save` | — |
| 7 | Run metrics aggregation | `bash scripts/metrics-aggregator.sh` | Docs-only skip |

### Pre-Flight Protocol (Session Start)

Every agent runs this protocol at session start, before any work:

| # | Step | Tool |
|---|------|------|
| 1 | Load orchestration envelope | lean-ctx ctx_knowledge recall --key "orchestration-contract" |
| 2 | Read session state | lean-ctx ctx_read session/state.md |
| 3 | Read project vision | lean-ctx ctx_read PROJECT.md |
| 4 | Recall recent patterns | lean-ctx ctx_knowledge recall --query "architecture" |
| 7 | Load relevant skills | /skill matching domain |

**One-shot alias**: `save session` = all 8 post-flight steps. Always run the full protocol — partial saves lose audit trail, break resumption, or leave stale indexes.

## E2. Session Lifecycle

Every orchestration session persists its contract state to the `session/` directory for cross-session traceability and safe resumption.
> **LOCAL-ONLY:** `session/`, `.session/` and everything inside them are runtime state — NEVER `git add`, commit, or push them (gitignored; history grows unbounded). Archive historical state logs to `.session/` instead.


### Directory Layout

```
contract/                    ← Contract templates (immutable)
  contract.template.json
  contract.schema.json
  state.template.md

session/                     ← Live state + historical archive
  contract.json              ← Current orchestration contract
  contract.schema.json       ← Contract schema
  state.md                   ← Append-only log of ALL state transitions (LOCAL-ONLY, gitignored)

sandbox/                     ← Session playground (project root; contents gitignored)
  <session-slug>/            ← Scratch work for one live session
```

### Lifecycle Protocol

| Event | Action |
|---|---|
| **State transition** | Update `session/contract.json` → snapshot via `scripts/snapshot-contract.sh` |
| **Session end** (COMPLETE/BLOCKED) | Final snapshot → append summary to `session/state.md` → promote durable sandbox work, then prune the session folder (7-day TTL policy) |
| **Session resume** | Load `session/contract.json` + `session/state.md`; snapshot to record the resume |
| **Post-transition** | Run `update all states`: lean-ctx re-index → snapshot → save session |

Scratch work belongs in `sandbox/<session-slug>/`, one folder per live session. Writes stay inside your own folder, other sessions' folders are read-only, and nothing in the sandbox is committed. Promote anything durable before COMPLETE; full rules live in the project-root `sandbox/README.md`, the machine-readable form in `rules/rules.json` -> `enforcement.sandbox`.

The `session/state.md` is an append-only chronological log — every state transition creates a new entry with timestamp, session id, state, score, and summary. This provides a durable audit trail for every session.

### Snapshot Command

```bash
bash scripts/snapshot-contract.sh --summary "State: ${STATE} — brief description"   # Full snapshot
bash scripts/snapshot-contract.sh --snapshot-only                                      # Files-only
bash scripts/snapshot-contract.sh --dry-run --verbose                                  # Preview without changes
```

### Verification

```bash
ls -la session/                                    # contract.json, state.md
cat session/state.md                               # Chronological log
jq . session/contract.json                         # Current contract
```

### Why Session State Matters

Without a persisted session, contract state is lost between runs. The `session/` directory preserves:
- **Audit trail**: `session/state.md` grows monotonically — every state transition, every decision, every blocker
- **Safe resume**: `session/contract.json` is the exact state from the last run — no reconstruction needed
- **Discoverability**: `session/state.md` shows the full transition history at a glance

## E3. Audit-Observability

Reference: `skills/audit-observability/SKILL.md`. Load: `skill({name: "audit-observability"})`.

Three pillars of orchestration observability:

**1. State Contract Transitions** — Tracks every envelope state change: `INIT → PLAN → PLAN_SCORED → ... → COMPLETE` or `BLOCKED`. Records transition timestamps and duration, score at transition time, which agent triggered the transition, escalation events and retry count. Useful for detecting stalled workflows, infinite retry loops, or unexpected state regressions.

**2. Score Analytics** — Aggregates scoring pipeline results over time: Tier 1 (rule-based) subtotals per phase, Tier 2 (LLM-as-judge) scores and rationales, combined verdict distribution (PASS / RETRY / BLOCKED), score trends (improving, degrading, or oscillating), and blast radius penalty frequency. Score analytics feed into the metrics.* contract fields.

**3. Cross-Service Consistency Enforcement** — Validates that all services, agents, and components adhere to the shared contract: envelope schema compliance across all agents, uniform scoring criteria application, consistent state machine rule interpretation, and contract field naming and type consistency.

## E4. Conventions Checking

Five scripts maintain code quality, architecture conventions, and contract integrity. All are integrated into CI and should be run before commit.

**`scripts/validate-contract.sh`** — Seven-step envelope validation: JSON validity, required fields, state enum validation, nested field structure, content quality scoring, field-level ACL enforcement, and transition validation against rules/rules.json. Enforces the contract envelope integrity at every state change.

```bash
bash scripts/validate-contract.sh --file session/contract.json --score
```

A validation failure triggers a Tier 1 scoring deduction of 15 points and may BLOCK the transition.

**`scripts/check-conventions.sh`** — Project-wide conventions check: JSON Schema compliance of `session/contract.json`, file and directory structure conventions, naming patterns and project layout rules, and scoring pipeline configuration consistency. Run before any PR.

```bash
scripts/check-conventions.sh
```


```bash
```

**`scripts/detect-parallel-conflicts.sh`** — Detects overlapping file modifications from parallel agents. Accepts file lists or unified diffs. Required when `scope.parallel_eligible` is true to prevent conflicting writes.

```bash
bash scripts/detect-parallel-conflicts.sh --file1 /tmp/a.txt --file2 /tmp/b.txt
```

**`scripts/persist-contract.sh`** — Atomic envelope persistence via temp-file + rename pattern with optional score injection. Prevents partial writes that could corrupt the contract envelope.

```bash
bash scripts/persist-contract.sh --file session/contract.json --inject-score 85
```

### Automation Scripts (Auto-Persist & Scoring)

**`scripts/auto-persist.sh`** — Unified contract persistence. Writes the orchestration envelope to both lean-ctx knowledge and `session/contract.json` in one atomic call. Supports `--dry-run`, `--no-knowledge`, `--no-file`, `--session`, and `--triggered-by` flags. Automatically detects state transitions and appends audit log entries.

```bash
bash scripts/auto-persist.sh                              # Persist current session
bash scripts/auto-persist.sh --dry-run                    # Preview without writing
bash scripts/auto-persist.sh --triggered-by developer     # Tag the source agent
```

**`scripts/auto-score.sh`** — Three-tier automated scoring pipeline. Runs Tier 1 rule-based checks (schema, permissions, blast radius, writing order, required fields), Tier 2 LLM-as-judge (when available), and computes the combined PASS/RETRY/BLOCKED verdict. Mirrors the scoring logic from the orchestration contract.

```bash
bash scripts/auto-score.sh --file session/contract.json --rules rules/rules.json
bash scripts/auto-score.sh --file contract.json --rules rules.json --score-only   # Just the number
```

### Guard & Recovery Scripts

**`scripts/state-guard.sh`** — Agent state access verification. Checks if an agent is allowed to operate in the current contract state by reading `rules.json agent_states`. Prevents agents from being called in states they don't have access to.

```bash
bash scripts/state-guard.sh --agent system-analyst --state PLAN     # PASS
bash scripts/state-guard.sh --agent system-analyst --state EXECUTE  # BLOCKED
```

**`scripts/self-repair.sh`** — Contract corruption recovery. Validates the current contract, scans `session/` for valid snapshots when corruption is detected, and restores from the newest valid snapshot. Requires `--force` for auto-restore; prompts by default.

```bash
bash scripts/self-repair.sh                              # Check + auto-detect
bash scripts/self-repair.sh --dry-run                    # Preview restoration
bash scripts/self-repair.sh --force                      # Restore without prompt
```

**`scripts/drift-detect.sh`** — Drift detection between lean-ctx knowledge and file versions of the contract. Compares 5 key fields (`state`, `score.combined`, `score.verdict`, `session.task_id`, `retry.attempt`) and reports discrepancies.

```bash
bash scripts/drift-detect.sh                             # Auto-detect session
bash scripts/drift-detect.sh --verbose                   # Show all field values
```

### Prototype Mode & Uncertainty Routing


```bash
bash scripts/prototype-mode.sh --enable             # Enable prototype mode
bash scripts/prototype-mode.sh --disable            # Disable, restore full orchestration
bash scripts/prototype-mode.sh --status             # Check if prototype mode is active
bash scripts/prototype-mode.sh --enable --verbose   # Enable with detail
```

**`scripts/uncertainty-router.sh`** — Uncertainty-Based Routing (G27). Routes decisions based on confidence/uncertainty level. Thresholds are read from `rules.json -> decisions.confidence_journal` (maps 1-5 scale to 0-100). Routing: 0-30 → ESCALATE to user (exit 2), 31-60 → COUNCIL/REVIEW (exit 1), 61-85 → PROCEED WITH NOTES (exit 0), 86-100 → AUTO-APPROVE (exit 0). Supports `--advisory-only` for non-blocking recommendation mode. Domain-specific guidance for code, architecture, security, deployment, testing, and requirements decisions.

```bash
bash scripts/uncertainty-router.sh --score 25 --domain architecture    # ESCALATE
bash scripts/uncertainty-router.sh --score 75 --domain code --advisory-only  # Advisory
bash scripts/uncertainty-router.sh --score 95 --domain deployment      # AUTO
```

### Spec Gate & Knowledge Verification

**`scripts/sdd-gate.sh`** — SDD (Spec-Driven Development) gate enforcement. Checks if a change touches >3 files, crosses service boundaries, or is estimated >30 min. If so, requires an approved spec before EXECUTE delegation. Supports trivial fix, config-only, and doc-only exemptions.

```bash
bash scripts/sdd-gate.sh --file session/contract.json
bash scripts/sdd-gate.sh --file contract.json --estimate 30
```

**`scripts/verify-knowledge.sh`** — Knowledge persistence verification. Queries lean-ctx knowledge base for expected categories (architecture, patterns, testing, lessons) and reports coverage. PASS at ≥70% coverage, FAIL below.

```bash
bash scripts/verify-knowledge.sh --phase PLAN
bash scripts/verify-knowledge.sh --all
```

### Analytics & Trend Scripts

**`scripts/trend-analyzer.sh`** — Score trend analysis over time. Reads session/contract.json and session/state.md to detect regression patterns, score trends (improving/degrading/oscillating), and produce sparkline visualizations. Supports --days N, --all-sessions, --json output modes.

```bash
bash scripts/trend-analyzer.sh                                  # Last 7 days by default
bash scripts/trend-analyzer.sh --days 30 --all-sessions         # 30 days, all sessions
bash scripts/trend-analyzer.sh --json                           # Machine-readable output
```

**`scripts/metrics-aggregator.sh`** — Cross-session quality metrics aggregation. Produces summary statistics (total sessions, avg score, pass rate), by-state breakdowns, timeline views, and quality metrics (avg issues per phase, retry rate, avg duration). Reads from session/state.md (falls back to session/contract.json).

```bash
bash scripts/metrics-aggregator.sh                              # Default summary mode
bash scripts/metrics-aggregator.sh --mode by-state              # Breakdown by state
bash scripts/metrics-aggregator.sh --mode timeline              # Timeline view
bash scripts/metrics-aggregator.sh --mode quality               # Quality metrics
```

### MCP Reliability Scripts

**`scripts/mcp-retry.sh`** — Auto-retry with configurable backoff strategies for MCP failures. Supports exponential, linear, and fibonacci backoff modes with configurable base delay (default 1s), max delay (default 30s), and max retries (default 3). Includes jitter for thundering herd prevention and circuit breaker state tracking.

```bash
bash scripts/mcp-retry.sh --cmd "rag_status"         # Retry a command
bash scripts/mcp-retry.sh --cmd "curl $URL" --backoff linear    # Linear backoff
bash scripts/mcp-retry.sh --cmd "mcp-health.sh" --max-retries 5 # Increase retry limit
```

**`scripts/mcp-health.sh`** — MCP server health checks. Tests connectivity to lean-ctx, rag, sumopod API, and other MCP endpoints. Supports single-check and continuous monitoring modes. Returns pass/fail with response time and error details. Results are persisted to `session/health-record.md` for historical trend analysis.

```bash
bash scripts/mcp-health.sh                                      # Single check all endpoints
bash scripts/mcp-health.sh --continuous                         # Continuous monitoring
bash scripts/mcp-health.sh --check all                       # Check everything
```

### Feedback & Learning Scripts


**`scripts/post-mortem.sh`** — BLOCKED state post-mortem analysis. Analyzes the escalation trace from BLOCKED events and produces structured findings: root cause, failure pattern, lessons learned, and recommendations. Supports quick, deep, and report output modes.

```bash
bash scripts/post-mortem.sh --contract session/contract.json  # Analyze a BLOCKED contract
bash scripts/post-mortem.sh --session session --mode deep     # Deep analysis
bash scripts/post-mortem.sh --mode report                              # Generate full report
```

### Enforcement & Monitoring Scripts

**`scripts/contract-enforcer.sh`** — Runtime contract validation enforcement. Monitors contract state in real-time, validates transitions against rules.json, enforces agent→state MCP mappings, and can trigger BLOCKED transitions on violation. Supports validate (check only), enforce (auto-block), and mcp (agent-level enforcement) modes.

```bash
bash scripts/contract-enforcer.sh --mode validate              # Check contract state
bash scripts/contract-enforcer.sh --mode enforce               # Enforce with auto-block
bash scripts/contract-enforcer.sh --mode mcp --agent developer # Agent-level enforcement
```



```bash
bash scripts/scheduled-runner.sh --task drift-detect --schedule every-30   # One task on a 30-minute cadence
bash scripts/scheduled-runner.sh --foreground --task heal --schedule daily   # Supervised in-process loop
```



```java
```



## E5. lean-ctx Execution Flows

lean-ctx indexes the codebase as a knowledge graph. Current index stats: 1675 symbols, 1666 relationships, 0 execution flows.

**0 execution flows registered**: lean-ctx auto-detects execution flows when entry points are annotated. Currently no orchestration paths are mapped as lean-ctx processes. All lifecycle paths (INIT→PLAN→…→COMPLETE) are documented in Part A but not yet machine-annotated.

**Future work** — Add lean-ctx execution flow annotations to:
- **Orchestration lifecycle**: INIT → PLAN → PLAN_SCORED → EXECUTE → EXECUTE_SCORED → REVIEW → REVIEW_SCORED → COMPLETE
- **Scoring pipeline**: Delegation → Tier 1 rules → Tier 2 LLM judge → Tier 3 verdict → state transition
- **Escalation flow**: BLOCKED → persist → user intervention → resume with retry guidance

When flows are annotated, use `ctx_compose({query: "orchestration flow"})` for step-by-step traces or read `lean-ctx://repo/workflow-state-engine/process/{name}` for a specific flow.

See `skills/lean-ctx/` for the full annotation guide.

## E6. JSON Schema Reference

Full schema: `contract/contract.schema.json`. Validate against any envelope:

```bash
bash scripts/validate-contract.sh --file session/contract.json --score
```

The JSON Schema defines: required envelope structure for all fields (state, session, requirements, decisions, scoring, retry, outputs, metrics), valid state values and allowed transitions, type constraints (string, number, array, object) with field descriptions, and optional/required status per field. A validation failure triggers a Tier 1 scoring deduction of 15 points.

All agents should validate their envelope mutations against the schema before persisting. The orchestrator enforces schema compliance at every transition via Tier 1 rule checks.

## E7. health-check — Daily Health Check

Run the native health-check script to get a scored baseline of the workflow architecture:

```bash
lean-ctx ctx_shell /opt/engine/scripts/health-check.sh
```

The protocol (dimensions, weights, and scoring) is documented in `doc/health-check.md`. For a deeper guided review, paste this block into any AI chat:

```
Run the health-check protocol from doc/health-check.md to evaluate the current workflow architecture.

1. Load shared envelope — check current state, score trend, and open issues
2. Run scripts/health-check.sh — get a scored baseline
3. Review doc/workflow/*.md against actual scripts/*.sh — flag docs drift
4. Check session/health-record.md for score trend (up/down/flat)
5. Check session/state.md last 5 entries — spot recurring patterns
6. Cross-reference rules/rules.json agent_states with actual agents/*.md — are agents in sync with rules?
7. ctx_delta({scope: "compare", base_ref: "main"}) — any unexpected scope creep?

If health_score < 90: produce a gap analysis + fix plan (like the 15-gap campaign)
If health_score >= 90 with declining trend: flag the top 3 risk areas
If health_score >= 90 with stable/improving trend: confirm health, suggest 1 optimization
```

---

[workflow-shield]: https://img.shields.io/badge/Workflow-Orchestration-blue?style=for-the-badge
