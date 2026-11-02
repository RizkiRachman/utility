---
name: executing-plans
description: Executes implementation plans step by step. Follow the plan's task breakdown, dependency order, and success criteria. Includes blocker resolution, parallel dispatch, progress tracking, deviation handling, abort triggers, and checkpoint protocols.
---

# Executing Plans

Turn a structured plan into working code. This skill covers **what to do when things go wrong** — not just when they go right. Plans are hypotheses; execution is where reality pushes back.

> **Counterpart**: Use `writing-plans` to create the plans this skill executes.
> **Pre-flight**: Load the orchestration envelope first (`lean-ctx ctx_knowledge recall --query "orchestration-contract"`) — decisions, retry issues, and scope inform every execution decision.

---

## 1. Agent Mode Decision — developer vs fixer

Which agent executes the plan changes **how** you handle each task.

| Dimension | `developer` (full) | `fixer` (fixer) |
|-----------|--------------------|---------------------------|
| Scope | Multi-file, multi-service changes | Single bounded fix, single file or small cluster |
| Plan granularity | Step-by-step with verification | Single task, known root cause |
| Blocker escalation | Self-diagnose, try 2-3 strategies, then escalate | If stuck → escalate immediately (not diagnostic-capable) |
| Deviation | Document and adjust if < 20% of plan scope | Deviate only if the fix is clearly wrong — escalate otherwise |
| Test expectation | Write tests as part of plan | Run existing tests; do not add new test coverage |
| Checkpoints | Full post-flight per task | Single verify step at the end |

**Decision rule**: If the plan has 1-2 tasks and the root cause is known, use fixer. If the plan has 3+ tasks or requires design decisions, use developer.

---

## 2. Task Execution Flow

For each task in the plan:

```
┌─────────────┐     ┌─────────────┐     ┌──────────────┐     ┌───────────────┐
│  PRE-FLIGHT │ ──► │  EXECUTE    │ ──► │  VERIFY      │ ──► │  POST-FLIGHT  │
│  (check deps)│     │  (implement)│     │  (acceptance) │     │  (persist)    │
└─────────────┘     └─────────────┘     └──────────────┘     └───────────────┘
```

### 2.1 Pre-Flight

```text
□ 1. All dependencies (blocked-by tasks) are complete
□ 2. Scope files exist and are readable
□ 3. No pending conflicts with parallel work (check STATE.md)
□ 5. ctx_impact run on any symbols you plan to modify
□ 6. Acceptance criteria are concrete and verifiable (not vague)
```

If any check fails → enter **Blocker Resolution** (section 3).

### 2.2 Execute

Follow the writing order from AGENTS.md:
1. Port interface (`*InPort`, `*RepositoryPort`)
2. Domain service (implements `*InPort`)
3. Mapper (domain ↔ DTO, domain ↔ entity)
4. Adapter (orchestration via ports + mappers)
5. Constants (`AppConstants`, `ErrorCodes`, `ErrorMessageConstants`)
6. Events (`*EventOutPort` → `*EventAdapter` → handler)

**Implementation strategy per file type:**

| If it's a... | Strategy |
|---|---|
| New file | Write using `lean-ctx ctx_edit` with `create: true` or native `write` |
| Existing file | `lean-ctx ctx_edit` with exact `old_string` match,  |
| Rename | `ctx_refactor` — never find-and-replace |
| Test file | Write tests BEFORE production code (TDD) or alongside it; run `mvn test` immediately |

### 2.3 Verify

Against the task's acceptance criteria. Use these verification methods:

| Criterion type | Verify via |
|---|---|
| Compiles | `mvn compile -pl <module>` (or full project) |
| Passes tests | `mvn test` (includes ArchUnit) |
| Formatting | `mvn spotless:apply && mvn spotless:check` |
| No regressions | Before/after test count matches (run `mvn test | grep "Tests run:"` before and after) |
| API contract | If adding a REST endpoint, verify request/response DTO shapes |
| Event contract | If adding an event, verify publisher and handler both exist and match signatures |

### 2.4 Post-Flight

```text
□ 1. ctx_impact verify — blast radius matches expectations
□ 2. ctx_delta — only expected files changed
□ 3. Knowledge persist — save gotchas, patterns, decisions (lean-ctx ctx_knowledge remember)
□ 4. STATE.md update — append completed work, update Current Focus / Known Blockers
□ 5. Session save — ctx_session save
```

---

## 3. Blocker Resolution Strategies

When a task is blocked, work through these strategies in order. Time-box each attempt to 5 minutes.

### 3.1 Dependency Blocker (blocked-by task is incomplete)

```
Is the dependency truly blocking?
  ├── Yes, I need its output → Can I stub/mock it?
  │     ├── Yes → Create a stub, annotate as temporary, continue
  │     └── No  → Either wait or escalate to plan author
  └── No, I can work independently → Switch to an unblocked task
```

### 3.2 Test Failure Blocker (verification fails)

```
What kind of failure?
  ├── Compilation error → Fix the code; verify imports, signatures, generics
  ├── Unit test assertion → Check: is the test wrong or the code wrong?
  │     ├── Test outdated (spec changed) → Update test assertion
  │     └── Code incorrect → Debug the implementation
  ├── ArchUnit violation → Check AGENTS.md section 6 (Non-Negotiable Rules)
  │     └── Common: application/ imports infrastructure/, ports return Optional<T>
  ├── SpotBugs/PMD → Read the warning; fix the flagged pattern
  └── Flaky test (intermittent) → Run 3 more times to confirm; log known flake; continue
```

**Rule of thumb**: If you can't fix the failure in 3 attempts, do not keep trying — escalate. The plan may need adjustment.

### 3.3 Design Question Blocker (unclear how to implement)

```
Is the ambiguity in the plan spec or in the code?
  ├── Plan spec is ambiguous → Read the orchestration envelope decisions
  │     └── Still unclear? → Ask the orchestrator (not your own judgment)
  └── Code is complex/unfamiliar → Use doubt-driven-development
        ├── ctx_compose("concept") to find execution flows
        ├── ctx_compose("symbol") for 360° view
        └── If still uncertain, delegate to @explorer for analysis
```

### 3.4 Environment Blocker (build tool, dependency, config)

```
Problem category:
  ├── Missing dependency → Check pom.xml, repo availability, local ~/.m2/
  ├── Tool version mismatch → Verify Java 21, Maven 3.9+
  └── Persistent build issue → Run `mvn clean`, invalidate caches, retry
```

### 3.5 Escalation Path

If you've tried 2-3 strategies and the task is still blocked:

```text
1. Mark the task as BLOCKED in progress tracking (section 4)
2. Document: what was tried, what failed, what's needed
3. Switch to the next independent task (if any)
4. Report at end: "Task X is BLOCKED — <reason>. Needs: <specific help>."
```

Do not spend more than 15 minutes on a single blocker without escalating. Plans can be re-sequenced; time cannot be un-burned.

---

## 4. Progress Tracking

Track task state in the orchestration envelope (or in-memory for single-session plans).

### State Model

```
PENDING → IN_PROGRESS → VERIFIED → COMPLETE
                    ↓
                BLOCKED ←→ IN_PROGRESS (when unblocked)
```

### Tracking Format

```text
## Progress

| # | Task | State | Blocker | Notes |
|---|------|-------|---------|-------|
| 1 | Create ProductInPort | COMPLETE | — | Done |
| 2 | Create ProductService | IN_PROGRESS | — | Implementing findById |
| 3 | Create ProductController | BLOCKED | Blocked by task 2 | Waiting |
| 4 | Add product search event | PENDING | — | Not yet started |
```

### When to Update

- **Start a task**: Set to `IN_PROGRESS`
- **Hit a blocker**: Set to `BLOCKED`, document the blocker
- **Unblock**: Set back to `IN_PROGRESS`
- **Verified**: Set to `VERIFIED` (before moving on)
- **Completed post-flight**: Set to `COMPLETE`

---

## 5. Parallel Execution

### 5.1 Identifying Independent Work

Scan the dependency graph for tasks with no `blocked-by` relationship. These can run in parallel.

**Example dependency graph:**
```
Task A (port interface) ──blocked-by──→ Task B (domain service)
                                        Task C (mapper) ──independent of B──→ can run parallel
                                        Task D (web adapter) ──blocked-by B and C──→ must wait
```

### 5.2 Parallel Dispatch Strategy

If the current agent is `developer` and you have independent tasks:

1. Identify the largest independent chunk (the "critical path")
2. For independent tasks that are **pure implementation** (no design decisions), delegate to subagents or the orchestrator for parallel dispatch
3. For the critical path, work it yourself at
4. Re-merge at the next dependency merge point

**Rule of thumb**: Only parallelize if the independent tasks have:
- Clear acceptance criteria (no ambiguity)
- No shared mutable state
- Less than 30 minutes expected implementation time each

### 5.3 Parallel Risk

```
Risk: Two agents modify the same file
├── Mitigation: Assign files exclusively — no overlap
├── Mitigation: If overlap is unavoidable, serialize those tasks
└── Detection: ctx_delta() catches unexpected modifications
```

---

## 6. Deviation Handling

Plans are hypotheses. When reality diverges, decide whether to follow or adapt.

### Decision Framework

```
You discover something the plan didn't account for:

Is the deviation within the plan's scope?
  ├── Yes → Does the plan still describe the right approach?
  │     ├── Yes → Follow the plan, note the minor deviation
  │     └── No  → ADJUST: Update the task steps, keep the goal
  └── No → Does the deviation invalidate the plan's goal?
        ├── No → ADJUST: Note the scope change, modify affected tasks
        └── Yes → ABORT: The plan needs reworking (see section 7)
```

### When to Deviate Without Asking

You may adjust **implementation details** without escalation:
- Choosing a different method name (as long as ports don't change)
- Reordering private helper methods
- Adding minor defensive checks not in the spec
- Using a different data structure (same interface, better performance)

You must **ask** before:
- Changing a port interface signature
- Adding or removing a public method
- Changing the architecture pattern (e.g., synchronous → event-driven)
- Adding new dependencies (pom.xml)
- Expanding scope to additional files or modules
- Skipping acceptance criteria

### Deviation Log Format

```text
## Deviations

Deviation: <what happened>
Reason: <why the plan didn't account for it>
Impact: <what changed — scope, effort, risk>
Decision: <ADJUSTED / ESCALATED>
```

---

## 7. When to Abort

Some signals mean the plan should stop and be reworked, not pushed through.

### Red Flags — Stop and Escalate

| Signal | What it means | Action |
|--------|---------------|--------|
| **Pre-flight found existing bugs** (pre-existing test failures) | The plan assumed a clean baseline | Pause, document pre-existing issues, don't conflate with new work |
| **Impact analysis shows CRITICAL risk** | Change touches a hub symbol with widespread effects | Stop, report to orchestrator, do not proceed without re-architecture |
| **Work estimated > 3x original plan** | Underestimation — scope creep or complexity found | Stop at the 3x threshold, report, get a revised plan |
| **Deviation invalidates goal** (section 6) | The plan is now solving the wrong problem | Abort the plan, not the project — re-scope |
| **3+ consecutive blockers on different tasks** | Systematic issue (bad assumptions, wrong approach) | Do not keep pushing — the plan's model of the problem is wrong |
| **Test suite regression > 10%** | Unexpected behavioral change | Roll back, investigate root cause, do not patch over |
| **Blocker time exceeds execution time** | More time spent debugging than implementing | Stop, escalate. The approach is off. |

### Abort Protocol

```text
1. STOP all work immediately
2. ctx_delta() to see what's been modified
4. Report to orchestrator with:
   - Red flag triggered
   - Current state (what's done, what's partial)
   - Root cause analysis (why the plan failed)
   - Recommendation (re-plan, different approach, research needed)
5. Save session for continuity on re-plan
```

---

## 8. Checkpoint Protocol

Between tasks, run a lightweight checkpoint. This is the condensed version of the post-flight (section 2.4).

### Standard Checkpoint (3-step, ~30 seconds)

```text
□ ctx_delta()    — verify only expected files changed
□ mvn test                     — verify no regressions
□ lean-ctx ctx_session task —value "Task N complete: <summary>"
```

### Full Checkpoint (after every 3rd task or any risky change)

```text
□ ctx_impact verify on modified symbols
□ ctx_delta()
□ mvn spotless:apply && mvn test
□ Knowledge persist: lean-ctx ctx_knowledge remember ...
□ STATE.md update
□ ctx_session save
```

---

## 9. End-to-End Example

Given a plan with tasks [CreatePort, CreateService, CreateController, AddEvents]:

```text
1. PRE-FLIGHT: Check STATE.md, verify session state, ctx_impact
2. Task 1 (CreatePort): Implement port interface. VERIFY: compiles. CHECKPOINT.
3. Task 2 (CreateService): Implement domain service → blocked (ambiguous query method)
   → Blocker strategy: Read orchestration envelope → found previous decision → resolved
   → VERIFY: passes tests. CHECKPOINT.
4. Task 3 (CreateController): Implement web adapter
   → VERIFY: compiles, test passes. CHECKPOINT.
5. Task 4 (AddEvents): PENDING → not yet started → skip for now (lower priority)
6. POST-FLIGHT: ctx_delta, knowledge persist, STATE.md, session save
7. REPORT: 3/4 tasks COMPLETE, 1 task PENDING (AddEvents — not a blocker)
```

**Key principles in action**:
- Blockers are resolved systematically, not by guessing
- Checkpoints catch regressions early (not at the end)
- Work can stop at any point with a coherent state
- The orchestrator gets a clear status report, not confusion

---

## 10. Quick Reference Card

| Situation | Action |
|-----------|--------|
| Dependency blocked | Stub it or switch tasks |
| Test fails | Check test vs code, fix the broken one |
| Design unclear | Query lean-ctx, check envelope, or escalate |
| Build broken | Try `mvn clean`, check config, escalate |
| Independent work found | Parallelize with subagents |
| Deviation < 20% scope | Adjust and note it |
| Deviation > 20% scope | Escalate to orchestrator |
| CRITICAL impact risk | Stop, report, do not proceed |
| 3+ blockers in a row | Abort and re-plan |
| Between tasks | Run 3-step checkpoint |
| Every 3rd task | Run full checkpoint |
| All done | Post-flight protocol, report status |

---

*Last updated: 2026-06-16. Aligned with AGENTS.md writing order, non-negotiable rules, and pre-flight/post-flight protocols.*
