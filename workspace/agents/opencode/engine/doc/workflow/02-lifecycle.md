<!-- omit from toc -->

# Part B — Lifecycle Walkthrough: Phases, Gates, & BLOCKED

> See [doc/workflow/README.md](../workflow/README.md) for index.


## B1. Phase-by-Phase Walkthrough

### B1a. INIT → PLAN [Gate: DDD]

- **Reads**: requirements.* (goal, constraints, acceptance criteria), governance.*, retry.issues[]
- **Delegates to**: @product-manager (refine intent → GWT acceptance criteria, scope/non-goals) then @system-analyst (architecture analysis + implementation plan)
- **Gate**: DDD fires here — orchestrator asks "What assumptions am I making about scope and constraints?" before delegating. If the task is complex (>3 files, cross-service, >30 min estimate), DDD may recommend expanding scope or requesting user clarification.
- **Activity**: System-analyst runs ctx_impact on all affected symbols, traces execution flows, produces a structured plan with dependency graph, risk assessment, rollback strategy, task breakdown, and edge case analysis.
- **Outputs**: state=PLAN, session.* (task_id, created_at), scope.* (included paths, excluded paths, parallel_eligible) populated
- **Scoring threshold**: n/a (always advances to PLAN_SCORED for scoring)
- **Writes back**: contract.outputs.plan (full plan document), contract.decisions.* (architecture decisions made during planning)

### B1b. PLAN → PLAN_SCORED

- **Reads**: outputs.plan, scope.*, requirements.*
- **Delegates to**: @orchestrator (scoring pipeline — self-scored, not subagent)
- **Activity**: Run Tier 1 rule checks (schema valid, permissions, blast radius, writing order, over-engineering, required fields) → Tier 2 LLM-as-Judge (requirements fulfillment, governance compliance, completeness, edge cases) → Tier 3 combined verdict
- **Outputs**: state=PLAN_SCORED, score.* (rules subtotal, judge score, combined score, verdict), decisions.* (any refinements)
- **Gate**: Score ≥ 70 → PASS advances to EXECUTE. 50-69 → RETRY — re-delegate to system-analyst with issues[]. <50 → BLOCKED.
- **SDD gate trigger**: If score ≥ 70, SDD spec gate fires at the next transition. The plan is ready for spec-driven implementation.

### B1d. PLAN_SCORED → EXECUTE [Gate: SDD]

- **Reads**: score.* (proves ≥70), decisions.* (approved architecture), outputs.plan (full spec to implement from)
- **Gate**: SDD fires here — mandatory spec approval before any code is written. The plan must be in Given/When/Then format (or equivalent formal specification) before execution begins:
  1. System-analyst produces a spec with Given/When/Then
  2. Spec is scored (≥ 70 required) — if <70, revise spec
  3. Developer implements FROM the spec — every AC-N maps to at least one test
  4. Tests validate the spec — "Done When" conditions define exit criteria
  *Exempted for*: trivial bug fixes (1 file, <30 lines), config-only changes, documentation.
- **Delegates to**: @developer (implementation per spec, TDD cycle)
- **Writes back**: state=EXECUTE, governance.mode: spec, governance.current_guidance (any execution direction from orchestrator)

### B1e. EXECUTE → EXECUTE_SCORED

- **Reads**: outputs.plan (task breakdown, dependency graph), decisions.* (approved architecture, coding standard)
- **Simplicity**: The scoring pipeline includes a SIMPLICITY_001 rule (HIGH severity) that detects unnecessary abstractions, unused deps, and over-engineered patterns. An `over_engineering_deduction: 15` applies in Tier 1 when YAGNI violations are detected.
- **Delegates to**: @developer (implement per spec, Writing Order: port → service → mapper → adapter → constants → events → tests)
- **Activity**: TDD cycle per task (red → green → refactor), ctx_impact before every edit, tests alongside code
- **Outputs**: outputs.code_changes[] (files_created, files_modified), outputs.test_results (test_count, pass, fail)
- **Writes back**: state=EXECUTE_SCORED

### B1f. EXECUTE_SCORED → REVIEW [Gate: DDD]

- **Reads**: outputs.code_changes[], outputs.test_results, outputs.plan (for scope comparison)
- **Delegates to**: @orchestrator (scoring pipeline — self-scored)
- **Gate**: DDD fires here — "What would I criticize about my own code?" Orchestrator runs an adversarial self-review before delegating to quality-analyst. If DDD reveals gaps, they are flagged in risks_introduced[] for the reviewer.
- **Activity**: Score implementation (Tier 1 → Tier 2 → Tier 3). Pass ≥ 70 advances to REVIEW.
- **Writes back**: state=REVIEW, score.* (updated with implementation score)

### B1g. REVIEW → REVIEW_SCORED [Gate: Scoring + Over-Engineering Check]

- **Reads**: score.* (proves ≥70), outputs.* (code_changes, test_results, risks_introduced[])
- **Delegates to**: @quality-analyst + @security-engineer (independent, cross-model review — 5 axes)
  - Is every abstraction justified? Any YAGNI violations?
  - Could stdlib or existing deps replace any custom code?
  - Any unnecessary indirection (factories, interfaces with one impl, over-abstracted patterns)?
  - Could any file be eliminated entirely?
  - Are any new dependencies avoidable?
- **Activity**: Review 5 axes — correctness, readability, architecture, security, performance (plus DB/DevOps operability where applicable). @security-engineer performs the dedicated threat-model/secrets/trust-boundary pass.
- **Outputs**: outputs.agent_reports[] with findings per dimension, outputs.review_verdict (PASS/BLOCK/FLAG)
- **Writes back**: state=REVIEW_SCORED

### B1h. REVIEW_SCORED → COMPLETE

- **Reads**: outputs.agent_reports[], score.*, outputs.code_changes[], outputs.test_results
- **Delegates to**: @orchestrator (score review findings) + @learner (post-exec analysis); @scrum-master enforces the Definition of Done before COMPLETE
- **Activity**: Score review (Tier 1 → Tier 2 → Tier 3). Score ≥ 70 → COMPLETE. The learner extracts lessons, identifies patterns and gotchas, persists knowledge_updates[] to lean-ctx ctx_knowledge.
- **Outputs**: state=COMPLETE, lessons_learned[], metrics.* (cost_tokens, elapsed_ms, agents_used, phases_completed), knowledge_updates[]
- **Writes back**: Full envelope to lean-ctx, archive snapshot via scripts/snapshot-contract.sh

### DDD Gate Firing Summary

Doubt-Driven Development (DDD) subjects non-trivial decisions to adversarial review. It fires at 5 points across the lifecycle:

1. **B1a** (INIT→PLAN) — "What assumptions am I making about scope and constraints?" Before delegating to system-analyst, the orchestrator challenges the task framing.
2. **B1f** (EXECUTE_SCORED→REVIEW) — "What would I criticize about my own code?" Before review, the orchestrator runs an adversarial self-review of the implementation.
3. **Before commit** — "What did I miss?" Developer runs DDD on every non-trivial change before committing (branches, cross-service calls, shared state modifications).
4. **After review** — "Did the reviewer find what I expected?" After quality-analyst review, the orchestrator compares DDD predictions against actual findings.
5. **At BLOCKED** — "What assumption was wrong?" Every BLOCKED event triggers a root-cause challenge to avoid repeating the same failure.

DDD triggers when: code introduces >2 branches (if/else, switch, try/catch), calls cross-module boundaries, modifies shared state, or sits in a hot path or transaction. Load via `/skill doubt-driven-development`.

## B2. BLOCKED State: Escalation & Resume

When state becomes BLOCKED, all agents must follow this strict escalation protocol before any retry attempt. **Owner: @scrum-master** — it drives the escalation, arbitrates via @council when reviewers disagree, and tracks the retry count.

1. **Immediate stop** — Do NOT continue execution. All agents halt. Any in-flight work is discarded.
2. **Persist last state** — Save envelope with `state=BLOCKED`, populate `retry.issues[]`, append to `retry.escalation_trace[]`:
   ```json
   {
     "phase": "PLAN|EXECUTE|REVIEW",
     "blocked_at": "ISO-8601",
     "reason": "Summary of why blocked",
     "issues": ["issue1", "issue2"],
     "attempt": 1
   }
   ```
   The escalation trace is an append-only array — each BLOCKED event adds a new entry. This preserves full escalation history across retry cycles.
3. **Escalate to user** — Summarize blockers: `"I hit BLOCKED at ${phase}. Issues: ${issues}. Please review."`
4. **Wait for user response** — No polling loop. The orchestrator waits for user input. User may: adjust scoring threshold, provide fix guidance, override to continue, or discard the task entirely.
5. **Resume from INIT** — User response triggers BLOCKED→INIT transition. A fresh envelope is created for the retry. Previous `retry.issues[]` and `retry.escalation_trace[]` are preserved for context — the retry learns from past failures.
6. **Max 3 retries** — If the same phase blocks 3 times (checked via `retry.attempt`), permanent BLOCKED. User must explicitly override with `retry.override: true` to continue.

**Timeout guard**: If scoring pipeline exceeds `scoring.timeout_ms` (default: 30s), treat as scoring failure and set state=BLOCKED with issue `scoring_timeout`.

**DDD at BLOCKED**: DDD fires on every BLOCKED event — "What assumption was wrong?" This question feeds into the retry guidance and helps avoid repeating the same failure pattern.

## B2a. Prototype Mode — Lightweight Alternative

**Status**: Conceptual feature documented for future implementation. Not yet enforced by `state-machine.ts`. Currently relies on agent discipline to skip steps.

For rapid prototyping, low-risk experiments, or early-stage exploration, the orchestrator can switch to **Prototype-First Mode** (G26). This bypasses the full state machine for a faster, low-ceremony workflow:

| Full Orchestration | Prototype Mode |
|---|---|
| SDD gate required before EXECUTE | SDD gate **skipped** |
| Three-tier scoring pipeline (PLAN_SCORED, EXECUTE_SCORED, REVIEW_SCORED) | Scoring pipeline **bypassed** |
| Multi-pass execute with retry cycles | **Single-pass** execute |
| Formal review gate (quality-analyst) | **Auto-complete** (no review gate) |

**When to use**: Exploratory code, experimental features, spike solutions, proof-of-concept work, or any change where speed > rigor. Prototype mode should not be used for production-critical changes, security-sensitive code, or cross-service modifications.

**State persistence**: Mode state is stored in `session/.mode` (JSON: `{"mode":"prototype","enabled_at":"..."}`). A legacy marker `.prototype-mode` is also created for backward compatibility.

```bash
bash scripts/prototype-mode.sh --status   # Check mode
bash scripts/prototype-mode.sh --enable  # Switch to prototype mode
bash scripts/prototype-mode.sh --disable # Restore full orchestration
```

## B2b. Uncertainty-Based Routing for Decisions

When confidence in a decision is low, the orchestrator routes to appropriate escalation paths using **Uncertainty-Based Routing** (G27). This works alongside the lifecycle gates:

- **Confidence 0-30** → ESCALATE to user for human judgment (exit 2)
- **Confidence 31-60** → COUNCIL/REVIEW for multi-agent consensus (exit 1)
- **Confidence 61-85** → PROCEED WITH NOTES; flag concerns for later review (exit 0)
- **Confidence 86-100** → AUTO-APPROVE without further review (exit 0)

**Scale Mapping**: `rules.json → decisions.confidence_journal` uses a 1-5 scale. Map to 0-100 as follows:

| 1-5 Scale | 0-100 Scale | Meaning |
|-----------|-------------|---------|
| 1 (Guess) | 0-20 | No evidence, pure speculation |
| 2 (Informed) | 21-40 | Partial evidence, uncertain |
| 3 (Confident) | 41-60 | Supported by data, reasonable |
| 4 (Strong) | 61-80 | Multiple corroborating sources |
| 5 (Certain) | 81-100 | Verifiable, deterministic |

The `--advisory-only` flag emits the recommendation without blocking execution.

```bash
bash scripts/uncertainty-router.sh --score 25 --domain architecture     # Blocks, escalate
bash scripts/uncertainty-router.sh --score 75 --domain code --advisory-only  # Advisory
```

Uncertainty routing feeds into the DDD framework — when a decision routes to COUNCIL or ESCALATE, the DDD doubt table is triggered to document the adversarial analysis.

## B3. Learning Loop (Lessons → Knowledge)

After every COMPLETE transition, the learner extracts lessons from the session and persists them to the knowledge base. This creates a closed learning loop:

1. **Extract lessons** — learner reads outputs.*, score.*, retry.issues[] from the completed envelope
2. **Identify patterns** — What went well? What went wrong? What to change next time? What gotchas were discovered?
3. **Persist knowledge** — Write to lean-ctx ctx_knowledge with category (architecture, testing, governance) and key patterns
4. **Feed forward** — The next session's pre-flight protocol recalls recent patterns, so lessons from session N influence session N+1

The `lessons_learned[]` array in the contract envelope captures the raw output. The learner transforms this into structured knowledge_updates[] that are persisted to the knowledge graph for cross-session learning.

---

[workflow-shield]: https://img.shields.io/badge/Workflow-Orchestration-blue?style=for-the-badge
