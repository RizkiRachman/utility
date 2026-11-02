---
name: subagent-driven-development
description: Develops software by delegating bounded work to specialized subagents. Maximizes parallel execution for multi-file, multi-domain changes.
---

# Subagent-Driven Development

## Overview

Subagent-Driven Development (SDD) is the discipline of splitting a task into independent units, delegating them to specialized subagents, and reconciling the results. It converts sequential work into parallel work — but **parallelism amplifies both speed and risk**. A sub-agent working on wrong assumptions produces bad output faster.

This skill covers the full lifecycle: scope splitting → delegation → reconciliation → conflict resolution → quality gates → failure recovery. It is designed for the orchestrator (`@orchestrator`) to delegate to `@fixer`, `@explorer`, `@librarian`, and other subagents.

## When to Use

| Condition | Decision |
|-----------|----------|
| ≥2 independent files to modify | Strong candidate |
| Files span multiple domain packages | Strong candidate |
| Tasks have no shared state | Excellent candidate |
| Each unit fits in ≤50 subagent steps | Good candidate |
| Sequential dependencies exist | Run serial, or merge groups |
| Files share a common parent class | **Caution** — risk of conflicting edits |
| One sub-agent's output is input to another | Must be serial (or chain via knowledge) |

**When NOT to use:** One-file changes, simple refactors, tasks with tight coupling between components, or when the orchestrator's overhead exceeds the time saved.

---

## Parallel vs Serial Decision Framework

| Factor | Parallel | Serial |
|--------|----------|--------|
| File overlap | No shared files | Any shared files |
| Dependency graph | Independent results | A depends on B's output |
| Task size | Each ≥15 min of work | Each <5 min of work |
| Risk tolerance | Low blast radius | High blast radius |
| Human review windows | Async review possible | Needs synchronous review |
| Confidence in spec | High (clear requirements) | Low (needs iterative refinement) |

**Rule of thumb:** If you can write each sub-agent's spec in 3 bullet points without referencing another sub-agent's work, it's safe to parallelize. If the specs reference each other, run serial.

---

## Scope Boundaries: Splitting Work Cleanly

Clean scope boundaries are the single most important factor for successful parallelization. Two sub-agents touching the same file **will** conflict.

### File-Level Isolation (Preferred)

Assign each sub-agent **disjoint file sets**:

| Sub-agent | Files | Domain |
|-----------|-------|--------|
| fixer-A | `*InPort.java` + `*Service.java` | Port/service layer |
| fixer-B | `*Mapper.java` + `*Adapter.java` | Adapter layer |
| fixer-C | `*Test.java` | Test layer |

### Package-Level Isolation

If files must overlap (e.g., editing the same class for different reasons), use package-level assignment:

| Sub-agent | Scope | Exclusion |
|-----------|-------|-----------|
| fixer-A | `application/domain/service/` | No web/persistence |
| fixer-B | `infrastructure/adapter/web/` | No domain/service |
| fixer-C | `infrastructure/adapter/persistence/` | No web/domain |

### Method-Level Isolation (Last Resort)

When a sub-agent must modify a shared file, specify exact method boundaries:

```
fixer-A:  lines 10-45  (createReceipt method)
fixer-B:  lines 46-90  (updateReceipt method)
fixer-C:  lines 91-130 (deleteReceipt method)
```


---

## Delegation: Writing Sub-Agent Specs

Every sub-agent spec must contain **all** of these:

```text
Task: <one-sentence goal>
Files to modify:
  - path/to/FileA.java (lines X-Y: <what to change>)
  - path/to/FileB.java (lines X-Y: <what to change>)
Conventions:
  - Follow project: AGENTS.md, writing order
  - Writing order: port → service → mapper → adapter → constants → events → tests
  - Architecture: hexagonal, no infra imports in application/
Quality gates:
  - mvn spotless:apply
  - mvn compile (affected modules)
  - All tests pass
Do NOT touch:
  - path/to/FileC.java (assigned to another agent)
  - path/to/FileD.java (not in scope)
```

**Do NOT include:** References to other sub-agents' work, shared state, or cross-cutting concerns. Each spec must be **self-contained**.

---

## Reconciliation Strategies

After all sub-agents complete, merge their outputs.

### 1. Sequential Merge (Default)

Process sub-agent outputs one at a time, in dependency order:

```text
1. Apply fixer-A's changes (port + service layer)
2. Run mvn compile — verify no new breakage
3. Apply fixer-B's changes (mapper + adapter)
4. Run mvn compile
5. Apply fixer-C's changes (tests)
6. Run mvn test
```

**Use when:** Sub-agents modified different layers but the layers have implicit dependencies.

### 2. Parallel Merge (Safe for Disjoint Files)

Apply all changes, then verify in one pass:

```text
1. Collect all diffs from sub-agents
2. Verify file sets are disjoint (no overlap)
3. Apply all diffs in batch
4. Run mvn compile + mvn test
```

**Use when:** You validated file-level isolation before delegation.

### 3. Sequential Merge

```text
1. Collect each sub-agent result in order
2. Apply changes one at a time
3. Re-run tests after each apply
```

**Use when:** High-risk changes, or when file overlap is unavoidable.

---

## Conflict Detection


### Pre-Apply Check

For each pair of sub-agents (A, B):

```text
3. If any file is in both lists → CONFLICT detected
```

### Resolution Strategies

| Conflict Type | Resolution |
|---------------|------------|
| Same file, different methods | Manually merge both hunks |
| Same method, different logic | Run serial: apply A, verify, tell B the new state, re-delegate |
| Same file, one adds import | Apply both, run `spotless:apply` |
| Same constant/value | Verify both match — likely fine |
| Same test file | Assign tests to ONE sub-agent only |

**Never auto-merge conflicting outputs.** Two sub-agents producing contradictory logic means the spec was ambiguous — resolve the ambiguity first.

---

## Quality Gates Per Sub-Agent

Before accepting any sub-agent's output, verify:

| Gate | Check | Auto/Manual |
|------|-------|-------------|
| Compilation | `mvn compile -pl <module>` | Auto |
| Tests | `mvn test -pl <module>` | Auto |
| No scope creep | No additional files modified beyond spec | Manual |
| Null safety | No introduced `Optional<T>` returns (project bans them) | Manual |
| Arch rules | No `application/` imports from `infrastructure/` | ArchUnit test |
| Test coverage | At minimum: happy path + error path | Manual |

**Fail fast:** If compilation fails, do NOT accept partial output. Fix or re-delegate.

---

## Failure Recovery

| Failure Mode | Symptom | Action |
|-------------|---------|--------|
| Compilation error | `mvn compile` fails | Re-delegate with the error message as context |
| Test failure | ≥1 test fails | Re-delegate with failing test name + error |
| Scope creep | Files outside spec modified | Revert those files, accept rest |
| Wrong approach | Output doesn't match intent | Re-spec with more detail, re-delegate |
| Agent timeout | Sub-agent exceeded step limit | Split the task into smaller chunks |
| Incomplete output | Missing files from the spec | Re-delegate with checklist of missing items |

**Recovery steps:**

```text
1. Diagnose: compilation error, test failure, or design mismatch?
2. Collect evidence: the error/crash/incorrect output
3. Enrich spec: add the error context, clarify the approach
4. Increment retry counter (max 3)
5. Re-delegate
6. If retry ≥ 3: serialize and do it yourself
```

**Escalation:** After 3 retries or on architectural disagreements, stop delegating. Switch to serial execution with full orchestration oversight. Log the failure in `lessons_learned`.

---

## Integration with Orchestrator Workflow

This skill operates within the orchestrator's state machine (`orchestrator`):

```text
PLAN_SCORED ──→ EXECUTE ──→ [delegate phase] ──→ GATHER ──→ EXECUTE_SCORED
                     │                              │
                     ▼                              ▼
               Split into units              Reconcile outputs
               Delegate to subagents         Run quality gates
               (parallel or serial)          Handle failures
```

### Envelope Contract Updates

The orchestrator must update the orchestration contract after each delegation round:

| Milestone | Contract Update |
|-----------|----------------|
| Before delegation | `governance.current_guidance` = "delegating to N sub-agents" |
| Sub-agent launched | `metrics.agents_used[]` += agent name |
| Sub-agent completed | `outputs.agent_reports[]` += agent's summary |
| Reconciliation done | `outputs.code_changes[]` = merged results |
| All quality gates pass | `state` → `EXECUTE_SCORED` |

### Agent State Contract

Sub-agents (`@fixer`, `@explorer`, `@librarian`) operate as **support agents** with contract state `["*"]` — they can be called from any orchestrator state. They do NOT advance the state machine; only the orchestrator does.

---

## Practical Example: Three-Way Parallel Delegation

**Task:** Add CRUD endpoints for a new entity (`Vendor`) to the price service.

**Step 1: Split scope**

| Sub-agent | Files | What to do |
|-----------|-------|------------|
| fixer-ports | `VendorInPort.java`, `VendorRepositoryPort.java` | Define port interfaces |
| fixer-service | `VendorService.java` | Implement domain service |
| fixer-web | `VendorController.java`, `VendorDto.java`, `VendorMapper.java` | Web adapter |
| fixer-persistence | `VendorEntity.java`, `VendorJpaRepository.java`, `VendorRepositoryAdapter.java` | Persistence adapter |

**Step 2: Delegate in parallel**

Each gets a spec with exactly their files, following the writing order, with `Do NOT touch` sections for the other files.

**Step 3: Sequential merge**

Apply in layer order: ports → persistence → service → web. Run `mvn compile` after each layer.

**Step 4: Quality gates**

Run `mvn spotless:apply && mvn test` on the combined output.

**Step 5: Verify**

Ensure all files exist, no imports cross boundaries, all tests pass.
