---
name: orchestration-template
description: MANDATORY on EVERY task start — not just session start. Forces the orchestrator to load the shared orchestration envelope from lean-ctx BEFORE any work begins. If envelope exists → resume state. If not → ask user confirmation, then create fresh. Also use when user says "use orchestration template", "follow template", "resume", "continue", "check state". ALWAYS enforce this skill at the beginning of every task.
---

# Orchestration Template — Session Protocol

## When to load

Load this skill **first thing on every session start** and whenever the user says:

- "use orchestration template" / "follow template"

- "resume" / "continue our focus" / "check state"

- "orchestrate this" / "use the workflow"

## Protocol

### Step 1: Load the Envelope

```bash
lean-ctx ctx_knowledge recall --query "orchestration-contract"

```
→ Then check session archive: `ls session/` — if exists, load contract.json from there for full resume fidelity

### Step 2: Decision Gate

**If envelope FOUND:**

```text
→ Read state, session, decisions, governance, score, retry

→ Identify: current_phase, attempt, issues[]

→ Inform user: "Resuming at {state} (phase: {retry.current_phase}). Issues: {retry.issues}"

→ Load STATE.md → identify Current Focus

→ Continue from where the envelope left off

```
**If envelope NOT FOUND:**

```text
→ Ask user: "No orchestration session found. Use orchestration template? [Y/n]"

If YES:

  1. Read `/opt/engine/contract/contract.template.json` (seed) and the live envelope at `session/contract.json`

  2. Populate: session.task_id, session.session_id, session.created_at

  3. Persist via: lean-ctx ctx_knowledge remember key orchestration-contract:<task_id> value <JSON>

  3b. Establish session baseline: `scripts/snapshot-contract.sh --summary "Session init: {task_id}"`

  4. Sync STATE.md: set Current Focus = "New orchestration session: {task_id}"

  5. Proceed with the workflow

  6. First snapshot: `scripts/snapshot-contract.sh` — archive INIT state for resumption

If NO:

  → Skip orchestration. Work without the envelope.

  → Note: state, decisions, and retry will NOT be tracked.

```
### Step 3: Persist (on every transition)

After ANY delegation or phase change, run the **Save Session Protocol** — saves to ALL systems:

```bash
1. Persist envelope: Update state, outputs, score, retry, metrics → `lean-ctx ctx_knowledge remember key orchestration-contract:<task_id> value <updated JSON>`

2. Update state.md: Append completed work to `session/state.md`

3. Archive snapshot: `scripts/snapshot-contract.sh --snapshot-only`

4. Save conversation: `ctx_session save`


```

These 4 steps are the canonical **Save Session Protocol**. Run ALL of them — partial saves lose audit trail and break resumption.
### Step 4: Session Resume Detection

When resuming (envelope found with COMPLETE state):

```text
1. Read state + retry.current_phase + retry.issues

2. Update STATE.md Current Focus with "Resuming at {state} (phase: {retry.current_phase}). Issues: {retry.issues}"

3. Summarize to user: what was done, what's pending, any blockers

4. If blocked → ask user for guidance before continuing

5. **Snapshot on resume**: Run `scripts/snapshot-contract.sh` to record that the session was resumed (establishes baseline for continued work).

```
---

## State Machine

```text
INIT → PLAN → PLAN_SCORED → EXECUTE → EXECUTE_SCORED → REVIEW → REVIEW_SCORED → COMPLETE

                                                                                       ↘

BLOCKED (any phase) → user intervention → retry with guidance → back to failed phase

```
### Transition Rules

- `PLAN_SCORED → EXECUTE` — only if `score.combined ≥ 70`

- `EXECUTE_SCORED → REVIEW` — only if `score.combined ≥ 70`

- Any phase → `BLOCKED` — if `score.combined < 50` OR `retry.attempt ≥ 3`

### Block-On Criteria (validation.block_on)

- Test failures > 3 → BLOCKED

- Score drop > 30 points → BLOCKED

- Compile errors > 1 → BLOCKED

- code-reviewer verdict = BLOCK → BLOCKED

---

## Quick Reference

```bash
  lean-ctx ctx_knowledge recall --query "orchestration-contract"

  # Save Session Protocol (all 6 steps):
  lean-ctx ctx_knowledge remember key orchestration-contract:<task_id> value "<updated JSON>"
  # Update contract/state.template.md
  bash scripts/snapshot-contract.sh --snapshot-only   # archive snapshot
  lean-ctx ctx_session save                            # save conversation
```
