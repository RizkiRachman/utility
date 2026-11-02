---
name: token-optimize
description: Guidelines for efficient token usage - how to read files, batch operations, and manage context to minimize token consumption
license: MIT
compatibility: opencode
tags:
  - token-efficiency
  - context-management
  - cost-optimization
  - compression
file_patterns:
  - "**/*.md"
metadata:
  role: optimizer
triggers:
  - "token efficiency"
  - "save tokens"
  - "compress output"
  - "be concise"
  - "too verbose"
  - "context window"
---

# Token Optimization Guide

## Core Principles

1. **Search before reading** — `lean-ctx ctx_search` to find, then `lean-ctx ctx_read` only the relevant section

2. **Read sections, not files** — use `offset` and `limit` parameters

3. **Parallelize independent operations** — batch tool calls when no dependencies

4. **Reuse task context** — pass `task_id` for related work

5. **Be concise** — summaries, not dumps

---

## File Reading

**❌ BAD:** `read filePath="/src/Service.java"` (entire 500-line file)

**✅ GOOD:**

```bash
grep pattern="calculatePrice" path="/src"           # Find the line

read filePath="/src/Service.java" offset=120 limit=15  # Read only that section

```
**Rule:** If you only need a method signature, read 50 lines max. If you need implementation, read 30-50 lines around the target.

---

## Batch Operations

**❌ BAD:** Sequential reads (each waits for previous)

**✅ GOOD:** Parallel reads for independent files:

```bash
read filePath="/Product.java"

read filePath="/Order.java"

read filePath="/Customer.java"

# All three execute simultaneously

```
**Combine searches:**

```bash
grep pattern="class (Product|Order|Customer)"  # One search, not three

```
---

## Context Management

- **Narrow scope:** `glob pattern="src/main/java/com/example/service/**/*.java"` not `**/*`

- **Summarize findings:** "ProductService has 6 CRUD methods. Key: createProduct() uses ProductRepository.save()"

- **Clear context when switching tasks:** summarize, discard, start fresh

---

## Task Context Reuse

**Use same `task_id` when:**

- Continuing implementation on same feature

- Adding to recently created code

- Fixing bugs in recently written code

**Start fresh (new `task_id`) when:**

- Switching to completely different feature

- After long gap (context likely stale)

- Working on unrelated module

---

## Token Budget

| Phase | Budget | Activity |
|-------|--------|----------|
| Discovery | 10% | glob + grep to find files |
| Analysis | 30% | read key sections |
| Implementation | 50% | write code |
| Verification | 10% | run tests, check quality |

**Warning signs:** Reading same file multiple times, loading entire directories, verbose explanations, not using `task_id` for related work.

---

## Quick Reference

**Before reading files:**

- [ ] Can I `lean-ctx ctx_search` to find the specific line first?

- [ ] Do I need the whole file or just a section?

- [ ] Can I use `limit` and `offset`?

**Before tool calls:**

- [ ] Can these calls be parallelized?

- [ ] Can I combine searches?

- [ ] Do I already have this info in context?

