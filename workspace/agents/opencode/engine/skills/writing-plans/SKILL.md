---
name: writing-plans
description: Creates structured, actionable implementation plans from requirements. Plans include dependency graphs, risk assessment, rollback strategy, task sizing, parallelization, and integration with the orchestration contract.
---

# Writing Plans — Production-Ready Plan Methodology

Creates structured, actionable implementation plans from requirements. Every plan must be executable by a developer subagent without back-and-forth clarification.

## When to Use

- Starting a new feature or significant change across multiple files
- Requirements are gathered but not yet sequenced into tasks
- Need to scope work before delegating to developers or subagents
- Orchestrator needs to populate `outputs.plan` in the contract envelope
- Before any execution phase in the state machine (`PLAN` → `PLAN_SCORED` → `EXECUTE`)

## Plan Format — Required Section Structure

Every plan MUST include these sections in order:

```markdown
## Goal
Single-sentence objective. What does success look like?

## Acceptance Criteria
Checklist of verifiable outcomes (pass/fail, no ambiguity).

## Scope
- **Files to create**: absolute paths
- **Files to modify**: absolute paths
- **Files to delete**: absolute paths
- **Out of scope**: explicitly excluded files/modules

## Dependency Graph
ordered list with block/blocked relationships (see §Dependency Graph Analysis below).

## Task Breakdown
Numbered tasks with: owner, estimated size (S/M/L/XL), files touched, verification step.

## Risk Assessment
Known challenges, uncertainties, and mitigations (see §Risk Assessment below).

## Rollback Strategy
What to revert if a task fails (see §Rollback Planning below).

## Edge Cases & States
- Input validation boundaries
- Null/empty/missing data
- Concurrent access
- Idempotency requirements
- Failure modes

## Parallel Execution Plan
Which tasks can run concurrently and which agents handle them (see §Parallel Execution)

## Verification Steps
How each acceptance criterion is validated (compile? test? manual? review?)
```

---

## 1. Dependency Graph Analysis

### How to Derive Dependencies

Every implementation task depends on one or more **predecessors**. Identify them by answering:

| Question | Dependency Type | Example |
|----------|---------------|---------|
| Does this task need a type/interface to exist? | **Interface dependency** | `ReceiptInPort` must be written before `ReceiptService` |
| Does this task need data from another task? | **Data dependency** | Repository must be implemented before service tests |
| Does this task need a schema to exist? | **Schema dependency** | DB migration must run before repository adapter |
| Does this task depend on a contract from another domain? | **Cross-domain dependency** | `PriceService` needs `ProductInPort` from product domain |
| Does this task depend on an event being published? | **Event dependency** | Handler needs the event class and publisher to exist |

### Dependency Encoding

Use a DAG adjacency list format. Each task lists what it **blocks** and what it **depends on**:

```text
Task 1: Create ReceiptInPort interface
  Depends on: nothing (root task)
  Blocks: Task 2, Task 3

Task 2: Create ReceiptService
  Depends on: Task 1 (needs ReceiptInPort)
  Blocks: Task 4 (testing)

Task 3: Create ReceiptRepositoryPort interface
  Depends on: nothing (root task)
  Blocks: Task 5

Task 4: Write ReceiptService unit tests
  Depends on: Task 2 (needs implementation), Task 5 (needs repository mock)
  Blocks: nothing (leaf task)
```

**If a task has no dependencies and nothing depends on it — question whether it belongs in the plan.** Isolated tasks are often scope creep.

### Cycle Detection

Before finalizing the plan, scan for circular dependencies (A → B → C → A). If found:
1. **Extract a shared interface** that both sides can depend on
2. **Introduce an event** to break the synchronous coupling
3. **Re-architect** the coupling direction

---

## 2. Risk Assessment

### Risk Classification

Score each task on two axes:

| Likelihood | 1 (Rare) | 2 (Unlikely) | 3 (Possible) | 4 (Likely) | 5 (Almost Certain) |
|------------|----------|-------------|-------------|-----------|-------------------|
| **1 (Negligible)** | 🟢 1 | 🟢 2 | 🟢 3 | 🟡 4 | 🟡 5 |
| **2 (Minor)** | 🟢 2 | 🟢 4 | 🟡 6 | 🟡 8 | 🟠 10 |
| **3 (Moderate)** | 🟢 3 | 🟡 6 | 🟠 9 | 🟠 12 | 🔴 15 |
| **4 (Major)** | 🟡 4 | 🟠 8 | 🟠 12 | 🔴 16 | 🔴 20 |
| **5 (Catastrophic)** | 🟡 5 | 🟠 10 | 🔴 15 | 🔴 20 | 🔴 25 |

**Thresholds**: 🟢 1-4 = low risk, 🟡 5-10 = medium (flag), 🟠 11-15 = high (mitigation required), 🔴 16-25 = critical (architectural review required)

### Common Risk Patterns (Project-Specific)

| Pattern | How to Detect | Mitigation |
|---------|--------------|------------|
| **Cross-domain event coupling** | Service publishes event consumed by another domain | Write contract test for event shape; use `@Async` + `@TransactionalEventListener(AFTER_COMMIT)` |
| **Schema migration in hot path** | Adding NOT NULL column to large table | Add column as nullable first, backfill, then add NOT NULL |
| **Third-party API integration** | LLM calls, external price feeds | Add circuit breaker, timeout, and fallback; mock in unit tests |
| **Shared infrastructure change** | Modifying `common/` package or `config/` | Run `ctx_impact` — HIGH/CRITICAL blast radius means staggered rollout |
| **ArchUnit rule violation** | Adding import from `infrastructure/` to `application/` | Pre-review with ArchUnit; cannot merge if rule fails |
| **New dependency / library** | Adding maven dependency | Check OWASP (`mvn verify -P security-check`); verify it's already in the BOM |

### Early Risk Discovery

Run these **before writing the plan**:
1. `ctx_impact({target: "<affected classes>", direction: "upstream"})` on every class you plan to change
2. For API changes: `ctx_impact({route: "/api/..."})`
3. Label risks as: `known`, `discovered-during-planning`, or `assumed-low-risk`

---

## 3. Rollback Planning

### Per-Change-Type Rollback Strategy

Every task MUST specify how to revert if it fails mid-flight:

| Change Type | Rollback Strategy | Example |
|-------------|-------------------|---------|
| **Schema migration** | Write a **down migration** (`V2__undo.sql`) before applying `V2__change.sql` | "Run V2__undo.sql, then delete the migration file" |
| **External API change** | Feature flag — toggle back to old implementation | "Set `feature.llm.new-prompt=false`" |
| **Event handler change** | Deploy new handler as a separate listener; old handler still active | "Stop the new handler via config" |

### Rollback Section in Plans

Each task's rollback block looks like:

```text
### Task 3: Add receipt price calculation
If migration applied, run V3__undo.sql first.
Impact: Receipt price calc will fall back to pre-change values.
```

---

## 4. Task Sizing Heuristics

### Size Classes

| Size | Files | Lines of Change | Subagent Sessions | Example |
|------|-------|-----------------|-------------------|---------|
| **S** (Small) | 1 file | ≤ 30 lines | 1 session, ≤ 5 min | Rename a method; add a constant |
| **M** (Medium) | 2-4 files | 30-100 lines | 1 session, ≤ 15 min | New port interface + domain service method |
| **L** (Large) | 5-10 files | 100-300 lines | 1-2 sessions, ≤ 1 hour | New domain service + repository + event |
| **XL** (Extra Large) | 10+ files | 300+ lines | 2+ sessions, multi-hour | New domain; cross-cutting refactor |

### Splitting Heuristics

| Symptom | Fix |
|---------|-----|
| Task has 3+ "depends on" entries | Split — the predecessor chain is too long |
| Task modifies 8+ files | Split — consider separating interface from implementation |
| Task spans 3+ layers (port, service, adapter, event) | Split — one task per layer |
| Task description contains "and also" | Split — that's two tasks |
| Task can't be verified independently | Split — add a verification step or merge with dependent task |

### Anti-Pattern: The Integration Sandwich

❌ **Bad**: Task "Implement receipt upload" — involves frontend DTO, controller, service, repository, event, handler, test (14 files, 600 lines). Cannot verify until all pieces exist.

✅ **Good**: Split into:
1. Create `ReceiptInPort` + `ReceiptService` (implementation, testable with mocks) — **M**
2. Create `ReceiptRepositoryPort` + adapter + schema migration — **M**
3. Create event flow (`EventOutPort` → adapter → handler) — **M**
4. Wire controller + DTO mapper + integration test — **L**

Each task is independently testable.

---

## 5. Parallel Execution Opportunities

### Identifying Parallel Tasks

Tasks are parallelizable when their dependency sets are **disjoint**:

```text
Task A  (depends on: nothing)          Task D  (depends on: B)
Task B  (depends on: A)       →        Task E  (depends on: C)
Task C  (depends on: A)                 → B and C can run in PARALLEL after A
```

### Heuristic Rules

| Pattern | Parallel? | Why |
|---------|-----------|-----|
| Two port interfaces in the same domain | ✅ YES | No shared state; both are pure definitions |
| Port interface + its implementation | ❌ NO | Implementation depends on the interface |
| Repository port + event port in same domain | ✅ YES | Different concerns, same dependency level |
| Service for domain X + service for domain Y | ✅ YES | No coupling if they communicate via events |
| Migration + migration rollback | ❌ NO | Rollback must match the forward migration |
| Web adapter + event handler for same service | ✅ YES | Different entry points, same service interface |

### Agent Assignment for Parallel Tasks

```text
Wave 1 [agent-1, agent-2]:
  agent-1 → Create ReceiptInPort
  agent-2 → Create ReceiptRepositoryPort

Wave 2 [agent-1, agent-2]:
  agent-1 → Create ReceiptService (needs ReceiptInPort)
  agent-2 → Create ReceiptAdapter  (needs ReceiptRepositoryPort)

Wave 3 [agent-1]:
  agent-1 → Wire controller + test
```

### Constraints

- Max parallel agents: set in contract `scope.max_parallel_agents` (default 1)
- Never parallelize tasks in the same file (merge conflicts)
- Different domains → safe to parallelize; same domain → check shared types first

---

## 6. Integration with System Analyst + Orchestration Contract

### Feeding into the Contract

The system-analyst produces a plan. The plan populates these fields in `contract.json`:

| Contract Field | Plan Output |
|---------------|-------------|
| `scope.included` | File paths from the Scope section |
| `scope.excluded` | Explicitly out-of-scope paths |
| `scope.parallel_eligible` | Whether any tasks are parallelizable |
| `scope.max_parallel_agents` | Number of parallel waves × agents per wave |
| `requirements.goal` | Goal section (copied verbatim) |
| `requirements.acceptance_criteria` | Acceptance Criteria section |
| `requirements.constraints` | From scope rules + architectural constraints |
| `decisions.approved_architecture` | Any architecture decisions made during planning |
| `outputs.plan` | The full plan text (serialized as string) |

### Workflow

```text
system-analyst (planning)
    │
    ├── 1. Read requirements from contract.requirements
    ├── 2. Run ctx_impact on all affected symbols
    ├── 3. Produce plan (this skill)
    ├── 4. Populate contract.outputs.plan
    └── 5. Persist: lean-ctx ctx_knowledge remember key orchestration-contract ...

orchestrator (scoring)
    │
    └── 6. Score plan (≥70 → EXECUTE, <70 → revise)

developer (execution)
    │
    └── 7. Read plan from contract.outputs.plan + execute tasks
```

### Plan Handoff Convention

The plan is persisted as `contract.outputs.plan` in the orchestration envelope:

```bash
lean-ctx ctx_knowledge remember \
  category architecture \
  key orchestration-contract \
  value '<contract JSON with outputs.plan populated>'
```

The executor (developer) loads it at session start:
```bash
lean-ctx ctx_knowledge recall --query "orchestration-contract"
# Extract contract.outputs.plan → execute task breakdown
```

---

## 7. Plan Quality Verification

### Quality Checklist — Score Each Item 0 or 1

| # | Criterion | How to Verify |
|---|-----------|---------------|
| 1 | Every task has a single owner | No "agent-1/agent-2" in same task |
| 2 | Every task is independently verifiable | Task acceptance criteria are specific enough to write a test |
| 3 | Dependency graph has no cycles | Walk the adjacency list; detect A→B→A |
| 4 | No task is XL (300+ lines) | If XL, split into subtasks |
| 5 | Every task has a rollback strategy | Per change type (see §3) |
| 6 | Risks are scored (1-25) | No unlabelled risks |
| 7 | Acceptance criteria are pass/fail | No "should improve" — must be "returns 200" or "query returns rows" |
| 8 | Scope includes exact file paths | Not "the price module" but `price/app/domain/service/PriceService.java` |
| 9 | Edge cases are documented | Null, empty, concurrent, failure — at minimum |
| 10 | Parallel waves are explicitly listed | Which tasks run in which wave and by which agent |

**Pass threshold**: 8/10. If < 8, revise the plan before submitting for scoring.

### Acceptance Criteria Anti-Patterns

| ❌ Bad | ✅ Good |
|--------|---------|
| "Price service works correctly" | "PriceService.getPrices() returns sorted list by date DESC for a valid storeId" |
| "Tests pass" | "All 5 new unit tests pass; ArchUnit rules 1-7 pass; no SpotBugs violations" |
| "Code is clean" | "spotless:apply passes; no magic strings; constants moved to ErrorCodes/AppConstants" |
| "Events fire correctly" | "ReceiptCreatedEvent is published with storeId and receiptId; handler logs to alert table" |

---

## Plan Template (Copy-Paste Ready)

```markdown
## Goal
{One sentence describing what this plan achieves}

## Acceptance Criteria
- [ ] {Criterion 1}
- [ ] {Criterion 2}
- [ ] {All tests pass: mvn test}
- [ ] {Formatting: mvn spotless:apply}

## Scope
### Files to Create
- `src/main/java/com/example/goodsprice/{domain}/.../...java`
- `src/test/java/com/example/goodsprice/{domain}/.../...Test.java`

### Files to Modify
- `src/main/java/com/example/goodsprice/{domain}/.../...java`
- `src/test/java/com/example/goodsprice/{domain}/.../...Test.java`

### Out of Scope
- {Explicitly excluded changes}

## Dependency Graph
{T1 depends on nothing; T2 depends on T1; T3 depends on T2}

## Task Breakdown
### Task 1: {Name} [S/M/L/XL]
- **Files**: {paths}
- **Predecessors**: {none or task IDs}
- **Successors**: {task IDs that depend on this}
- **Verification**: {how to check it works}
- **Rollback**: {how to undo}

### Task 2: {Name} [S/M/L/XL]
...

## Risk Assessment
| Risk | Likelihood | Impact | Score | Mitigation |
|------|-----------|--------|-------|------------|
| {risk} | {1-5} | {1-5} | {product} | {countermeasure} |

## Rollback Strategy
- {Per task or per change type — see §3 of Writing Plans skill}

## Edge Cases
- {Null/empty input, concurrent writes, failure recovery, idempotency}

## Parallel Execution Plan
- **Wave 1**: Task 1 (agent-1), Task 3 (agent-2) — parallel
- **Wave 2**: Task 2 (agent-1, needs T1), Task 4 (agent-2, needs T3) — parallel
- **Wave 3**: Task 5 (agent-1, needs T2 + T4) — sequential

## Verification Steps
1. `mvn compile` — all modules compile
2. `mvn test` — new + existing tests pass
3. `mvn spotless:apply` — formatting clean
4. `ctx_delta()` — only expected files changed
```

---

## Project-Specific Examples

### Example 1: Adding a new domain service (price alerting)

```markdown
## Goal
Add AlertService that checks if a product price drops below a threshold and fires an event.

## Acceptance Criteria
- [ ] AlertService.triggerIfBelowThreshold(productId, threshold) returns AlertResult
- [ ] AlertEventOutPort.publish(AlertCreatedEvent) is called when threshold met
- [ ] No prices → returns PassedResult.noAlert() — not an error
- [ ] All tests pass; ArchUnit rules pass; spotless:apply clean

## Dependency Graph
T1(AlertInPort) → T2(AlertService) → T4(AlertServiceTest)
T3(AlertRepositoryPort) → T2
T3(AlertRepositoryPort) → T5(AlertRepositoryAdapter)
T3(AlertRepositoryPort) → T6(schema migration V3__create_alert_table)

## Task Breakdown
### Task 1: Create AlertInPort [S]
- Files: `alert/app/port/in/AlertInPort.java`
- Predecessors: none

### Task 2: Create AlertService [M]
- Files: `alert/app/domain/service/AlertService.java`
- Predecessors: T1 (needs AlertInPort), T3 (needs AlertRepositoryPort)

### Task 3: Create AlertRepositoryPort [S]
- Files: `alert/app/port/out/AlertRepositoryPort.java`
```

### Example 2: Cross-domain event addition

```markdown
## Goal
When a receipt is corrected, trigger re-pricing of all line items.

## Risk Assessment (Critical)
| Risk | L | I | Score | Mitigation |
|------|---|---|-------|------------|
| Receipt domain depends on Price domain | 3 | 5 | 15 | Use event-driven coupling, not direct call |
| ReceiptCorrectedEvent shape changes affect existing handlers | 2 | 4 | 8 | Add fields only (backward-compatible); run ctx_impact on routes |

## Rollback Strategy
All changes are additive (new handler, new event). Revert by:
- No schema migration involved
```

---

## Quick Reference Card

```text
PLAN CHECKLIST                    │  RISK COLOR CODE
──────────────────────────────────│──────────────────
[ ] Goal is one sentence          │  🟢 1-4  = low (proceed)
[ ] Acceptance criteria pass/fail │  🟡 5-10 = medium (flag)
[ ] File paths are absolute       │  🟠 11-15= high (mitigate)
[ ] DAG has no cycles             │  🔴 16-25= critical (review)
[ ] No XL tasks (300+ lines)      │
[ ] Every task has rollback       │  PARALLEL RULES
[ ] Every risk is scored 1-25     │  Same layer, different domain = ✅
[ ] Edge cases documented         │  Same domain, different files = ✅
[ ] Parallel waves listed         │  Same file = ❌
[ ] Score ≥ 8/10 → ready          │  Depends on same predecessor = ❌
```
