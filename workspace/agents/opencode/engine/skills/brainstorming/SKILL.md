---
name: brainstorming
description: Divergent thinking for exploring solution spaces before converging on an approach. Generates multiple options, evaluates trade-offs, and selects the best path forward.
---

# Brainstorming

## Philosophy

A decision is only as good as the alternatives you rejected. Most projects converge too fast — the first viable approach gets implemented, and the second-best (but cheaper, simpler, or more maintainable) option never surfaces. This skill enforces structured divergence before convergence.

The goal is not to generate infinite options. The goal is to **find the best option** by making the space of possible approaches visible and comparable.

## When to Use vs. When to Skip

| Scenario | Use Brainstorming | Skip (use other skill) |
|---|---|---|
| Requirements are vague or exploratory | ✅ Generate options, then spec | ❌ Don't write code yet |
| Multiple valid architectural approaches | ✅ Map trade-offs systematically | ❌ Don't pick the first one |
| Refactoring legacy code | ✅ Compare extraction, rewrite, adapter strategies | ❌ Don't dive into implementation |
| Need to decide on tech/pattern adoption | ✅ Cost/benefit across dimensions | ❌ Don't just ask "does it work" |
| One-line fix or rename | ❌ Just do the edit | ✅ Use `fixer` |
| Bug has clear root cause | ❌ Fix it | ✅ Use debugging skills |
| Following a clear, unambiguous spec | ❌ Implement the spec | ✅ Use `spec-driven-development` |
| User explicitly said "just do it" | ❌ Ship it | ✅ Stop deliberating |

**Cost-benefit rule of thumb**: If the decision takes more time to deliberate than it would to revert a wrong implementation, skip the formal brainstorm. For a 1-hour revert window, 10 minutes of divergence is the max. For a decision you cannot revert (public API, data migration, DB schema), take the full time needed.

## The Core Loop: Diverge → Frame → Compare → Converge

```
DIVERGE:     Generate 3–5 structurally distinct approaches
  ↓
FRAME:       Define the evaluation dimensions (not just pros/cons)
  ↓
COMPARE:     Score each approach against each dimension
  ↓
CONVERGE:    Select + document rejected alternatives
```

### Step 1: DIVERGE — Generate structurally distinct options

**Rule**: Each option must differ in how it solves the core problem, not just in naming or implementation detail. If two options share the same architectural pattern (e.g., both use an event queue but with different tech), they count as one option — merge them and introduce a third that takes a completely different approach.

**Techniques for generating alternatives:**

| Technique | When | How |
|---|---|---|
| **Constraint flip** | Stuck on one approach | Pick the hardest constraint and remove it, then invert it. What if latency didn't matter? What if cost was no object? What if we had zero developers? Each extreme produces a different solution. |
| **YAGNI stress test** | Scope is growing | Explain each option to a developer who will maintain it in 6 months. If the explanation requires "well, we might need X later," that's scope creep masquerading as design. |
| **Worst-case-first** | Risk assessment is shallow | For each option, describe the production incident that will page the on-call at 3 AM. The option with the mildest pager scenario wins. |

**Bad divergence** (these are not structurally distinct):

> Option A: Use Redis for caching
> Option B: Use Memcached for caching
> Option C: Use Hazelcast for caching

**Good divergence**:

> Option A: In-process cache with TTL (simple, no network hop, restarts lose data)
> Option B: Distributed cache layer (complex infra, survives restarts, consistency tax)
> Option C: No cache — optimize the query instead (zero infra, zero staleness, may not be fast enough)

### Step 2: FRAME — Define evaluation dimensions

Pros/cons lists hide trade-offs behind vague words like "complex" or "clean." Instead, define **explicit dimensions** and score each approach against every dimension.

**Standard dimensions** (pick 3–5 per session):

| Dimension | What to measure | Scale |
|---|---|---|
| **Implementation effort** | Person-days to first working version | 1 (hours) → 5 (weeks+) |
| **Maintenance burden** | Cognitive load on future maintainers | 1 (trivial) → 5 (dedicated team needed) |
| **Operational risk** | Failure modes in production | 1 (safe) → 5 (cascading failure likely) |
| **Change flexibility** | Cost of changing requirements later | 1 (trivial swap) → 5 (rewrite needed) |
| **Performance** | Latency/throughput under expected load | 1 (exceeds reqs) → 5 (doesn't meet reqs) |
| **Testability** | Confidence that tests prove correctness | 1 (unit-testable) → 5 (E2E-only) |
| **Data consistency** | Stale/wrong data risk during normal ops | 1 (strong consistency) → 5 (eventual + conflict-prone) |

**Project-specific dimension templates** (from this codebase):

- **Hexagonal boundary violation risk**: Does this approach keep `application/` free of `infrastructure/` imports? (ArchUnit rule 1)
- **Event consistency tax**: Does this approach need `@TransactionalEventListener(AFTER_COMMIT)` or can it stay synchronous?
- **JPA coupling risk**: Does this approach introduce `@OneToMany` / `@ManyToMany` (forbidden by ArchUnit rule 4)?
- **Test isolation**: Can this be unit-tested with mocks, or does it require H2 + Flyway?

### Step 3: COMPARE — Score systematically

**Matrix format** (fill column by column, not row by row — this prevents anchoring on your favorite approach):

| Dimension | Option A: Cache in-process | Option B: Distributed cache | Option C: No cache |
|---|---|---|---|
| Implementation effort | 1 (existing library) | 3 (new infra dep) | 2 (query tuning) |
| Maintenance burden | 1 (zero config) | 3 (cluster mgmt) | 1 (SQL only) |
| Operational risk | 2 (stale on restart) | 3 (split-brain) | 1 (no new failure mode) |
| Change flexibility | 3 (flush on deploy) | 4 (config drift) | 1 (tune query, done) |
| Performance | 2 (~5µs hit) | 1 (~1ms, network) | 4 (DB bottleneck at scale) |
| Data consistency | 3 (stale reads) | 4 (eventual) | 1 (always fresh) |
| **Total** | **12** | **18** | **10** |

Lower is better. Option C wins because zero-infra solutions beat caching until the DB is proven the bottleneck.

### Step 4: CONVERGE — Select and document

**Convergence rules**:

1. If one option dominates (equal or better on every dimension), pick it — the matrix did the work.
2. If the top two options are close (≤3 points apart), the **simpler** one wins. Complexity must justify its weight.
3. If the top options disagree on priority dimensions (e.g., one is fast but fragile, another is slow but safe), the tiebreaker is: **which failure mode can you recover from faster?** Prefer recoverability over peak performance.
4. If still tied, surface to the user — there's a genuine value judgment an agent cannot make.

**After converging, always write**:

```text
DECISION: [selected approach]
REJECTED: [alternative 1] — reason: [dominant dimension where it lost]
REJECTED: [alternative 2] — reason: [dominant dimension where it lost]
RATIONALE: [tiebreaker logic, if any]
```

This documentation is not overhead — it saves future maintainers from re-arguing rejected alternatives six months later. Save it to `ctx_knowledge` under `decisions/` category.

## Project-Specific Examples

### Example 1: Cross-service receipt matching

**Problem**: Match incoming receipts to stored price records. Multiple correct answers (store, date, item name fuzzy match, tax calculation).

**Structured brainstorm** (Diverge → Frame → Compare):

**Option A**: Single SQL query with `WHERE item_name ILIKE '%input%' AND store_id = ? AND date BETWEEN ? AND ?`
**Option B**: Delegate to LLM — send receipt text, ask it to return the best match
**Option C**: Rule engine — configurable scoring rules (name similarity x weight + date proximity x weight + price accuracy x weight)
**Option D**: Two-phase — SQL narrows candidates (store + date ±2d), then scoring function picks best

**Frame dimensions**: Implementation effort, accuracy, explainability, testability, latency

| Dimension | A: SQL-only | B: LLM | C: Rule engine | D: Two-phase |
|---|---|---|---|---|
| Effort | 1 (one query) | 3 (prompt engineering) | 4 (rule DSL) | 2 (query + scorer) |
| Accuracy | 3 (fuzzy fails) | 2 (good with context) | 4 (brittle rules) | 1 (narrows + scores) |
| Explainability | 1 (SQL is transparent) | 4 (black box) | 2 (rules are readable) | 1 (both phases clear) |
| Testability | 1 (parameterized unit tests) | 4 (LLM non-deterministic) | 2 (rule unit tests) | 1 (query + scorer testable) |
| Latency | 1 (sub-ms) | 5 (seconds + API cost) | 2 (compute only) | 1 (one query + in-memory) |
| **Total** | **7** | **18** | **14** | **6** |

**Winner**: Option D (Two-phase). Best accuracy without LLM opacity, easiest to test, fast. Option A close — would win if accuracy requirements were lower.

**Rejected alternatives logged to `decisions/receipt-matching-strategy`**.

### Example 2: Event propagation pattern (sync vs. async)

**Problem**: When a price changes, the receipt service needs to re-evaluate any affected comparisons.

**Structured brainstorm**:

**Option A**: Direct service call — price service calls receipt service's REST endpoint
**Option B**: Spring `ApplicationEvent` + `@TransactionalEventListener(AFTER_COMMIT)` — publish event, receipt handler listens
**Option C**: Message queue (RabbitMQ / Kafka) — publish to topic, receipt consumer reads
**Option D**: Polling — receipt service periodically checks for recent price changes

| Dimension | A: Direct call | B: Spring event | C: Message queue | D: Polling |
|---|---|---|---|---|
| Effort | 1 (HTTP client) | 1 (existing pattern in codebase) | 4 (new infra dep) | 2 (scheduler + query) |
| Coupling | 4 (sync dependency) | 2 (event only) | 1 (fully async) | 1 (no coupling) |
| Consistency | 1 (immediate) | 2 (same tx boundary) | 3 (eventual) | 3 (eventual + delayed) |
| Ops risk | 3 (cascading failure) | 1 (same process) | 3 (broker is SPOF) | 1 (no new infra) |
| Latency | 1 (real-time) | 2 (post-commit async) | 2 (sub-second) | 4 (poll interval) |
| **Total** | **10** | **8** | **13** | **11** |

**Winner**: Option B (Spring event). Already the project's convention (see `@TransactionalEventListener(AFTER_COMMIT)` in AGENTS.md §6 rule 7). Lowest effort, lowest risk, aligns with existing ArchUnit enforcement. Option A would need circuit breakers. Option C would need a new Maven dependency and ops training.

## Red Flags

- **False consensus**: You picked Option A because it was proposed first. Re-read the matrix. If A is your favorite, score B and C first.
- **Choice-supportive bias**: After picking a winner, you stop evaluating it critically. Force yourself to describe the worst thing about your chosen option.
- **Hedging into complexity**: "Well, we could use X AND Y AND also add Z." Combination approaches should be rare — they compound complexity. Prefer the simplest single approach that satisfies requirements.
- **Premature convergence**: Scoring before generating enough structurally distinct options. If all options share the same architecture (event bus, caching, etc.), diverge more before scoring.
- **Fake trade-offs**: "Higher accuracy for higher latency" is a real trade-off. "Higher accuracy AND higher complexity" is not a trade-off — it's a cost with no benefit. Don't score options on dimensions where they don't differ meaningfully.
- **Row-by-row scoring**: Filling the matrix row-by-row anchors on the first option. Fill column-by-column so each option is evaluated independently.
- **Ignoring existing conventions**: A perfectly-scoreable Option C is worthless if it violates ArchUnit rules or project style. Score "convention alignment" explicitly.

## Observability — How to Know It Worked

| Signal | Good session | Bad session |
|---|---|---|
| Options generated | 3–5 structurally distinct | 1–2 similar variants |
| Matrix filled | All cells populated | Only pros/cons, no scores |
| Winner chosen | Clear from matrix or tiebreaker rule | Reached by discussion fatigue |
| Rejected options documented | Reasons logged, not just names | "We went with A" — no context |
| Decision persists | No re-litigation in next session | "Why didn't we consider B?" 2 weeks later |
| Session uses bounded time | Under 30 min for most decisions | Spun out into open-ended debate |

**Retrospective check**: Six months later, do the rejected alternatives still make sense? If not, the brainstorm missed a dimension. Adjust the dimension template for next time.

## Interaction with Other Skills

- **`doubt-driven-development`**: After brainstorming converges on a decision, use DDD to stress-test it. Brainstorming generates options; DDD ensures the chosen one survives adversarial review.
- **`spec-driven-development`**: If brainstorming produced a winner, write the spec before implementing. Don't skip from "we chose X" to "write X code."
- **`executing-plans`**: After convergence, hand the decision + rationale to an execution plan. Brainstorming is not implementation.

## Verification Checklist

After completing a brainstorming session:

- [ ] Generated 3+ structurally distinct options (not just tooling variants)
- [ ] Defined 3–5 evaluation dimensions before scoring
- [ ] Filled scoring matrix column-by-column (not row-by-row)
- [ ] Selected winner with explicit rationale (best score, tiebreaker rule, or user escalation)
- [ ] Documented rejected alternatives with reasons
- [ ] Total session time was proportionate to decision irreversibility
- [ ] Decision persisted to `ctx_knowledge` under `decisions/` category
