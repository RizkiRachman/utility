---
name: systematic-debugging
description: Debugs issues using the scientific method — hypothesis → isolate → fix → verify. Actionable templates, real Spring Boot scenarios, and project-specific tooling.
---

# Systematic Debugging

## Overview

Debugging is not a guessing game. It is the **scientific method applied to software**: form a falsifiable hypothesis, design the cheapest experiment that disproves it, interpret the evidence, repeat. This skill gives you the frameworks, templates, and project-specific tooling to execute that cycle efficiently.

The most common debugging mistake is **skipping the hypothesis step** and jumping straight to "try changing X." That's not debugging — that's cargo-culting. Every experiment must have a predicted outcome before you run it.

## When to Use

| Signal | Action |
|--------|--------|
| Test failure with unclear cause | Drop into this skill before changing any code |
| "It works on my machine" | Follow the environment comparison template |
| Production incident | Start with observability, skip to timeline reconstruction |
| Intermittent failure | Binary search + logging injection |
| Performance regression | Metric-first: profile before hypothesizing |
| "I don't know why this works" | You don't understand it — doubt-driven development |
| "I don't know why this broke" | This is the skill for that |

**When NOT to use:**
- The error message is unambiguous and the fix is known (e.g., "class not found" → missing import)
- You are reading code to understand it, not to fix it
- The fix was already identified by a CI gate (SpotBugs, ArchUnit, PMD) with a clear message

---

## The Scientific Method for Bugs

### Core Loop

```
1. REPRODUCE   — Establish a reliable trigger (not "sometimes")
2. OBSERVE     — Collect evidence: logs, state, stack traces, metrics
3. HYPOTHESIZE — Form a specific, falsifiable statement
4. EXPERIMENT  — Smallest test that disproves the hypothesis
5. INTERPRET   — Does the evidence confirm or refute?
6. LOCALIZE    — Narrow to the exact line/component/responsibility
7. FIX         — Minimal change addressing root cause
8. VERIFY      — Fix works + regression test + no side effects
```

**Rule of thumb**: If you can't state your hypothesis in one sentence of the form *"If X is the cause, then when I do Y, Z will happen"*, you aren't ready to experiment yet.

### Decision Tree

```
Bug reported
│
├─ Can you reproduce it reliably?
│   ├─ YES → Collect initial evidence
│   └─ NO  → Add logging at suspected boundaries → retry
│              Still can't reproduce?→ Check environment differences
│                                     → Check timing/race conditions
│                                     → Add structured event logging
│
├─ Do you have a stack trace or error message?
│   ├─ YES → Read bottom-to-top (cause is at the bottom)
│   │         Read top-to-bottom for the call chain
│   │         ← First frame in YOUR code is the entry point
│              What's different about this input?
│              Check assumptions: config, data, state
│
├─ Hypothesis formed?
│   ├─ YES → Design experiment (see templates below)
│   └─ NO  → Use 5 Whys or fishbone to surface assumptions
│
└─ Experiment result matches prediction?
    ├─ YES → Root cause found. Fix and verify.
    └─ NO  → Hypothesis refuted. Form the next one.
              (Never adjust evidence to match the hypothesis)
```

---

## Hypothesis Generation Frameworks

### Framework 1: The Assumption Stack

Every bug is a failed assumption. List your assumptions in order of **likelihood** — start with the layer that fails most often:

```
Configuration       — Wrong property? Wrong profile? Missing env var?
├─ application.yml, application-{profile}.yml
├─ @ConfigurationProperties bindings
└─ @Value fields

Data                — Null field? Wrong enum value? Stale cache?
├─ Database state (check directly with Postgres tool)
├─ Cache contents (Caffeine, Redis)
└─ API input/output shapes

Control flow        — Wrong branch? Missing event handler?
├─ @Async not firing (see detailed example below)
├─ @TransactionalEventListener ordering
├─ AOP interceptor ordering vs @Transactional
└─ Exception swallowed in catch block

Boundary            — Cross-module contract mismatch?
├─ Port interface contract vs adapter implementation
├─ Event shape vs handler expectation
└─ API DTO → Domain → Entity mapping
```

**Technique**: For each layer, ask *"If this layer were bug-free, would the symptom disappear?"* If yes, move to the next layer. If no, that layer is your suspect.

### Framework 2: The Three Dimensions

Most bugs come from exactly three sources. Classify your bug before hypothesizing:

| Dimension | Signal | Primary Tool |
|-----------|--------|-------------|
| **State** | Wrong value, stale data, null reference | Logs, Postgres queries, cache inspection |
| **Timing** | Race condition, async ordering, transaction interleaving | Thread dumps, @Async analysis, transactional boundaries |
| **Mapping** | Missing field, wrong type, dropped data during conversion | Mapper tests, JSON serialization, DTO ↔ Domain ↔ Entity trace |

### Framework 3: The Contradiction Method

When stuck, list everything that is **true about the system** and everything that is **true about the symptom**. Find the contradiction:

```
System truth:     @TransactionalEventListener(AFTER_COMMIT) runs after commit
Symptom truth:    The event handler never fires
Contradiction:    Either the event was never published, or commit never happened
New hypothesis:   The AOP interceptor ordering means publish() runs before @Transactional commits
                  → Real project example: CHANGELOG.md line 139
```

---

## Binary Search Strategies


When the bug is a regression but you don't know what caused it:

```bash
```


### 2. Component Isolation

Narrow the blame to one layer by testing boundaries in isolation:

```
Bug observed at:    API response has wrong price
├─ Isolate web:     Test the controller directly (MockMvc) → If wrong, bug is in adapter
├─ Isolate service: Test the service with known input → If wrong, bug is in domain
├─ Isolate DB:      Query PostgreSQL directly with the SQL JPA generates → If wrong, bug is in query
└─ Isolate mapping: Test DTO ↔ Domain ↔ Entity mappers in isolation → If wrong, bug is in mapping
```

### 3. Log-Based Narrowing

Add targeted logging at **suspected boundary points** — not everywhere. The goal is to binary-search the code path:

```java
// Before vs after a transformation
log.debug("Input to calculatePrice: receiptId={}, items={}", receiptId, items);
/* ... calculation ... */
log.debug("Output from calculatePrice: total={}, breakdown={}", result.total(), result.breakdown());
```

Add one pair of log statements. If both appear → bug is between them. If only the first appears → bug is before the second. Move the boundary and repeat.

### 4. Thread Dump Pattern for Async Bugs

For intermittent failures or async ordering issues:

```bash
# Take 5 thread dumps 1 second apart
for i in 1 2 3 4 5; do
  jstack $(pgrep -f your-app.jar) > thread-dump-$i.txt
  sleep 1
done
# Look for threads BLOCKED, WAITING, or in your code's package
grep -A 20 "BLOCKED\|WAITING" thread-dump-*.txt
```

---

## Logging Patterns for Debugging

### What to Log at Each Level

| Level | When to Use | What to Include |
|-------|-------------|-----------------|
| `ERROR` | Something is broken and needs human action | Exception, correlation ID, input that caused it |
| `WARN` | Something unexpected but not fatal | Degraded path taken, fallback used, retry count |
| `INFO` | Normal operation, significant lifecycle | Service start/stop, config loaded, batch completed |
| `DEBUG` | During active debugging — **never in production by default** | Method entry/exit with key params, transformation results |
| `TRACE` | Very granular flow tracing | Loop iterations, individual DB query results |

### Project Convention (from `@Slf4j` usage)

```java
// Log entry with key parameters
log.debug("calculateBestPrice: productId={}, storeIds={}", productId, storeIds);

// Log exit with result
log.debug("calculateBestPrice result: bestPrice={}", bestPrice);

// Log errors with exception (NOT with .getMessage() — pass the full exception)
log.error("Failed to process receipt receiptId={}", receiptId, exception);

// Log warnings for recoverable issues
log.warn("Cache miss for productId={}, falling back to DB", productId);
```

### Adding Targeted Logging Mid-Debug

```java
// 1. Add one log line at the suspected failure point
log.debug("=== DEBUG: price field before persist: price={}, isPromo={}", price.getValue(), price.getIsPromo());

// 2. Run and check output
// 3. If inconclusive, move the log point
// 4. DELETE the debug logs when done — never commit temporary logging
```

**Anti-pattern**: Adding 20 log statements at once. Add one. Move it. Delete it.

### Structured Logging Pattern

For production debugging, use structured fields so log aggregators can filter:

```java
log.warn("Price calculation degraded: receiptId={}, storeId={}, fallbackReason={}",
    Map.of("receiptId", receiptId, "storeId", storeId, "reason", reason));
```

---

## Root Cause Analysis Templates

### 5 Whys

Start with the symptom and ask "why" five times (or until you reach a system/code cause):

```
Symptom: Receipt correction doesn't update price summary
  Why? → The event handler ReceiptCorrectedPriceCalcHandler never fires
    Why? → The ReceiptCorrectedEvent is published but handler doesn't receive it
      Why? → Handler extends AbstractAsyncPriceCalcHandler which uses @Async("receiptApproveProcessorExecutor")
      Why? → The executor "receiptApproveProcessorExecutor" bean doesn't exist or is misconfigured
      Why? → Executor bean was renamed but handler annotation wasn't updated (ROOT CAUSE)
```

**Stop condition**: When the "why" answer is a **fixable code/config change**, not another symptom.

### Fishbone (Ishikawa) for Complex Bugs

```
                    Configuration                     Data                       Code
                    ┌────────────────────┐    ┌────────────────────┐    ┌────────────────────┐
                    │ Wrong profile?     │    │ Null field in DB?  │    │ Wrong branch taken? │
                    │ Missing env var?   │    │ Stale cache?       │    │ Exception swallowed?│
                    │ Executor names?    │    │ Event not saved?   │    │ Mapper drops field?│
                    └────────────────────┘    └────────────────────┘    └────────────────────┘
                                                       │
                                             ┌─────────▼──────────┐
                                             │  PRICE SUMMARY     │
                                             │  NOT UPDATED       │
                                             └─────────┬──────────┘
                                                       │
                    ┌────────────────────┐    ┌────────────────────┐    ┌────────────────────┐
                    │  Timing            │    │  Third-party       │    │  Build/Tooling     │
                    │ @Async ordering?   │    │ DB constraint?     │    │ SpotBugs false?    │
                    │ TX boundary?       │    │ API rate limit?    │    │ Compilation issue? │
                    │ Race condition?    │    │ Network timeout?   │    │ Dep version bump?  │
                    └────────────────────┘    └────────────────────┘    └────────────────────┘
```

### Timeline Reconstruction

For production incidents or bugs involving multiple services:

```
10:02:15 — Receipt POST /api/v1/receipts/create → 200 OK
10:02:16 — ReceiptCorrectedEvent published to ApplicationEventPublisher
10:02:16 — @TransactionalEventListener handler should fire (AFTER_COMMIT)
10:02:17 — Receipt marked as CORRECTED in DB
10:02:18 — Price summary NOT updated (BUG: handler didn't fire)
```

Fill in the timeline from logs, then look for **gaps** — where an expected event didn't happen, or happened out of order.

---

## Real Debugging Scenarios

### Scenario 1: @Async Method Not Executing

**Symptom**: An `@Async` method returns immediately but the work never happens.

**Assumption stack**:
1. `@EnableAsync` is present on a `@Configuration` class → `@SpringBootApplication` includes it
2. The executor bean name matches the annotation → `@Async("receiptProcessorExecutor")` matches a bean named `receiptProcessorExecutor`
3. The method is public and called from outside the class → self-invocation bypasses proxy
4. The `TaskExecutor` bean is configured with a queue capacity → tasks might be queued but never executed if queue is full

**Hypothesis**: "If the executor bean name doesn't exist, Spring will silently fall back to `SimpleAsyncTaskExecutor` which runs in the caller's thread — so the work WOULD happen but synchronously. If the method is called from the same class, the proxy is bypassed entirely."

**Experiment**: Add a breakpoint/log at the first line of the async method. Call the service. Does the log appear?

```java
// If log appears → method IS being called. Bug is inside the method.
// If log doesn't appear → either the caller never reaches this point,
//                         or the AOP proxy isn't being invoked.
```

**Project-specific check**: The project uses named executors (`receiptProcessorExecutor`, `activityLogExecutor`, `receiptApproveProcessorExecutor`). Check `@Async` annotation value matches exactly:

```java
// GOOD — matches executor bean
@Async("receiptApproveProcessorExecutor")
public void doExecute(ReceiptCorrectedEvent event) { ... }

// BAD — typo, bean won't be found
@Async("receiptApproveExecutr")
```

### Scenario 2: @TransactionalEventListener Not Firing

**Symptom**: An event is published with `applicationEventPublisher.publishEvent()`, the handler has `@TransactionalEventListener(AFTER_COMMIT)`, but it never executes.

**This is a real bug from the project CHANGELOG (line 139):**

**Root cause**: The AOP interceptor (e.g., `@ActivityLog`) runs **before** `@Transactional` advisor in the interceptor chain. The `eventOutPort.publishLogged()` call executes before the transaction commits. When `@TransactionalEventListener(AFTER_COMMIT)` checks "is there an active transaction that just committed?", the answer is **no** — because the transaction hasn't even started, or it started but hasn't committed.

**Hypothesis**: "The event is published before the transaction commits, so `AFTER_COMMIT` phase never fires."

**Experiment**: Change `@TransactionalEventListener(phase = TransactionPhase.AFTER_COMMIT)` to `@EventListener` (fires immediately). If the handler executes, the hypothesis is confirmed.

**Fix**: Either change the listener phase, or reorder the AOP interceptors so the `@Transactional` advice wraps the event-publishing code.

**Diagnostic checklist**:
- [ ] Is the event class registered? Spring events don't need registration, but check for accidental `@Async` on the **publish** side (might swallow exceptions)
- [ ] Is there an active transaction? Add `TransactionSynchronizationManager.isActualTransactionActive()` log
- [ ] Is the listener in a scanned package? Component scan must cover the handler package
- [ ] Is `@Async` on the same method as `@TransactionalEventListener`? This works, but if the executor has no capacity, the task is silently dropped

### Scenario 3: NotFoundException Returns 500 Instead of 404

**Symptom**: Domain service throws `NotFoundException.price(id)` but client gets HTTP 500.

**Assumption check**:
1. Is `GlobalExceptionHandler` registered as `@ControllerAdvice`? → Check the class annotation
2. Does the handler have a method for `NotFoundException`? → Check for `@ExceptionHandler(NotFoundException.class)`
3. Is the exception thrown **after** the controller boundary? → If thrown in a filter or interceptor, `@ControllerAdvice` doesn't catch it

```java
// This is handled by GlobalExceptionHandler → returns 404
@ExceptionHandler(NotFoundException.class)
public ResponseEntity<Map<String, Object>> handleNotFound(NotFoundException e) {
    return ResponseEntity.status(HttpStatus.NOT_FOUND)
        .body(Map.of("error", e.getErrorCode(), "message", e.getMessage()));
}
```

**Hypothesis**: "The exception is thrown in a `@Service` method called from the controller, so `@ControllerAdvice` should catch it — unless the exception is wrapped in another exception."

**Experiment**: Add a test that calls the controller and expects 404. If it gets 500, the handler isn't being invoked:

```java
mockMvc.perform(get("/api/v1/products/99999"))
    .andExpect(status().isNotFound());
```

### Scenario 4: DataIntegrityViolationException on NOT NULL Column

**Symptom**: Update operation fails with `DataIntegrityViolationException` — the column is `NOT NULL` but a null value is being persisted.

**Project example**: `PriceService.update()` could pass `null` for `isPromo` field, causing insert/update to fail.

**Isolation steps**:
1. Check the SQL: enable `spring.jpa.show-sql=true` or check PostgreSQL logs
2. Check entity field: does it have `nullable = false`?
3. Check the mapper: does the `toEntity()` method handle null → default?
4. Check the incoming DTO: is the field missing from the request?

```java
// Fix pattern used in project:
price.setIsPromo(ObjectUtils.defaultIfNull(updateRequest.getIsPromo(), false));
```

---

## Tooling Integration

### Using lean-ctx for Impact Tracing

Before changing anything during debugging, trace the blast radius:

```json
// Who calls the suspect method?
{"name": "ctx_impact", "arguments": {"target": "calculateBestPrice", "direction": "upstream"}}

// What does the suspect method call?
{"name": "ctx_impact", "arguments": {"target": "calculateBestPrice", "direction": "downstream"}}

// Full 360° context on a symbol
{"name": "ctx_compose", "arguments": {"name": "PriceService", "include_content": false}}
```

**Debugging-specific query**: Trace an execution flow end-to-end:

```json
{"name": "ctx_compose", "arguments": {"query": "receipt correction event flow", "task_context": "debugging receipt correction not updating price"}}
```

### Using lean-ctx_search for Code Path Finding

When you need to find all places where a particular field or method is used:

```
lean-ctx ctx_search --pattern "isPromo" --ext ".java" --path src/main
lean-ctx ctx_search --pattern "publishPriceSummaryUpdateRequested" --ext ".java"
```

### Using Postgres for DB-Level Debugging

When the bug is in data or query behavior, go directly to the database:

```json
// Check actual table contents
{"name": "postgres_pg_readonly", "arguments": {"sql": "SELECT * FROM prices WHERE product_id = 123 ORDER BY updated_at DESC"}}

// Check for missing rows the app expects
{"name": "postgres_pg_readonly", "arguments": {"sql": "SELECT p.* FROM prices p LEFT JOIN products pr ON p.product_id = pr.id WHERE pr.id IS NULL"}}

// Check schema — does the column exist? Is it nullable?
{"name": "postgres_pg_describe_table", "arguments": {"table": "prices"}}
```

---

## Observability: Metrics, Traces, Logs Together

### The Three Pillars in Debugging

```
METRICS — What is happening?
  ├─ Request rate (is traffic hitting the service?)
  ├─ Error rate (are errors spiking?)
  ├─ Latency p50/p95/p99 (is something slow?)
  └─ Use for: first alert, before you start debugging

TRACES — Where is it happening?
  ├─ Distributed trace across services
  ├─ Span: which operation took the longest
  ├─ Span: which operation failed
  └─ Use for: narrowing to the specific component

LOGS — Why is it happening?
  ├─ Exception details and stack traces
  ├─ Request parameters and state
  └─ Use for: root cause identification
```

### Order of Operations During a Production Incident

```
1. Check METRICS → Confirm the alert is real, not a false positive
2. Check TRACES → Find the component with the error or highest latency
3. Check LOGS → Read the error context for the affected trace
4. Form hypothesis → Based on all three data sources
5. Narrow via logs → Add targeted logging (in lower environments)
6. Fix and verify → Deploy fix, watch metrics return to baseline
```

### What to Check First (Quick Reference)

```
┌──────────────────────┬────────────────────────────────────┐
│ Symptom              │ First thing to check               │
├──────────────────────┼────────────────────────────────────┤
│ 404 instead of 500   │ @ControllerAdvice + @ExceptionHandler │
│ Handler never fires  │ AOP ordering vs @Transactional     │
│ Wrong data returned  │ Mapper: DTO → Domain → Entity      │
│ Null field in DB     │ @Column(nullable=false) + mapper   │
│ Stale data           │ Cache TTL + eviction trigger       │
│ Intermittent crash   │ Thread dump + connection pool      │
│ Build fails locally  │ Java version, Maven settings, deps │
│ @Async silent skip   │ Executor bean name mismatch        │
│ Rate limit triggered │ Bucket4j config + client IP header │
│ Event not received   │ @TransactionalEventListener phase  │
└──────────────────────┴────────────────────────────────────┘
```

---

## Verification Checklist

After applying a fix, run through these before calling it done:

- [ ] The fix reproduces no regression in existing tests (`mvn test`)
- [ ] A regression test was added that fails without the fix
- [ ] The root cause was identified (not just the symptom patched)
- [ ] The same bug pattern was searched across the codebase for siblings
- [ ] Spotless applied (`mvn spotless:apply`)
- [ ] Magnitude gates pass for affected module (`mvn verify`)
- [ ] The debugging logs were removed (never commit temporary logging)
- [ ] Knowledge captured: `lean-ctx ctx_knowledge remember --key "gotcha/<scenario>" --value "<root cause + fix>" --category "gotchas"`

## Red Flags

- Debugging by changing random things until it works
- Adding 20 log statements at once instead of moving one
- Fixing a symptom without understanding root cause
- "It works on my machine" without investigating environment differences
- Applying the same fix twice (first time didn't stick — meaning you don't understand the cause)
- Never running `ctx_impact` before the fix — did your change break other callers?
- No regression test added for a bug fix

## Interaction with Other Skills

- **`doubt-driven-development`**: After identifying a root cause, use doubt-driven to scrutinize your fix before committing. The fix *is* a non-trivial decision.
- **`lean-ctx-debugging`**: Use lean-ctx debugging skill for graph-traversal-based root cause analysis. This skill gives you the *process*; lean-ctx-debugging gives you the *tools*.
- **`simplify`**: After the fix, if the code is harder to understand than before, run simplify to reduce complexity.
- **`code-review-and-quality`**: The fix PR should go through review. Tag the root cause in the PR description.
