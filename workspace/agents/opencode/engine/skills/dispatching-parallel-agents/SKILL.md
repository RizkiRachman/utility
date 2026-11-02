---
name: dispatching-parallel-agents
version: 1.0.0
description: Coordinating multiple sub-agents for parallel execution — file-disjoint sharding, conflict avoidance, reconciliation.
---

# Dispatching Parallel Agents

## Overview

Parallel delegation multiplies throughput — and multiplies risk. Two sub-agents that touch the same file will conflict, and an orchestrator that cannot reconcile shard outputs loses both the speed and the correctness it gained. This skill defines the rules for dispatching multiple sub-agents in parallel: when it is allowed, how work is sharded, and how outputs are reconciled.

## When to Parallelize

Only parallelize when it is **provable** that the shards share no files:

| Condition | Verdict |
|-----------|---------|
| Shards touch provably disjoint file sets | Parallel allowed |
| Any file (or its parent module/package) appears in two shards | Serial only |
| One shard's output is another shard's input | Serial only |
| Shared mutable state (DB rows, caches, config files) is involved | Serial only |

If you cannot prove disjointness from the plan, run serial. "Probably disjoint" means serial.

## Hard Caps

- `max_parallel_agents` defaults to **1** (serial) and never exceeds **6**.
- Set it in the envelope (`scope.parallel_eligible`, `max_parallel_agents`) before dispatching.
- If the plan yields fewer clean shards than the cap, dispatch fewer — never pad shards to fill the cap.

## Sharding Rules

Each parallel agent receives its own slice of the work:

1. **Scope isolation** — each shard gets a `scope.included[]` slice containing only its own files. Overlapping paths across shards are a dispatching error: fix the shard boundaries, do not "coordinate carefully" around them.
2. **Shared context** — every shard receives the **same** `decisions.*` and `governance.*` from the envelope. Shards may differ in scope, never in rules.
3. **Conflict check before writing** — each shard runs `ctx_delta()` before writing to confirm no other shard has modified the same file.
4. **Scoped output** — each shard reports `files_created[]` / `files_modified[]` scoped to its own slice, tagged with its shard ID.

## Delegation Contract

For each shard the orchestrator must state:

- Shard ID and its exact `scope.included[]` slice
- The plan tasks assigned to that shard (no cross-shard tasks)
- The same decisions/governance context every other shard gets
- The reporting format: `files_created[]`, `files_modified[]`, `risks_introduced[]`, `review_focus[]`

## No Cross-Shard Dependencies

A shard must never wait on, stub for, or import another shard's output. If shard A needs code from shard B:

- Document the dependency in `risks_introduced[]`
- Do not write placeholder or stub code to unblock yourself
- Return early with the dependency flagged — the orchestrator re-sequences

## Reconciliation (Orchestrator Duty)

After all shards return, the orchestrator **MUST** reconcile before scoring:

1. Merge `files_created[]` / `files_modified[]` across shards
2. Run `ctx_delta()` — verify the combined change set matches the plan scope; flag drift
3. Check for file conflicts: the same file modified by two shards is a **dispatching failure**
4. **Re-delegate serially on any file conflict** — merge or split the overlapping work into a single serial agent; never hand-merge conflicting edits yourself
5. Run the scoring pipeline on the reconciled whole, not per shard

## Enforcement scripts

Two scripts mechanically enforce this skill's guarantees — run them at reconciliation time, before scoring:

- `scripts/detect-parallel-conflicts.sh` — post-shard conflict detection; compare two shards' contract scopes pairwise with `--file1` / `--file2`. Run after all shards return.
- `scripts/check-writing-order.sh` — writing-order gate (port → service → mapper → adapter) over a shard's committed files (`--dir`, optional `--file` for scope).

These scripts detect; they do not merge. Conflicts still re-delegate serially per the reconciliation duty above.

## Failure Recovery

| Symptom | Response |
|---------|----------|
| Shard modified files outside its slice | Verify with `ctx_delta()`, re-delegate that shard serially |
| Two shards claim the same file | Treat as conflict → serial re-delegation of the overlapping unit |
| Shard blocked on a cross-shard dependency | Re-sequence: run the dependency shard first, then the dependent one |
| Repeated conflicts across retries | Drop parallelism for this task — set `max_parallel_agents: 1` |
