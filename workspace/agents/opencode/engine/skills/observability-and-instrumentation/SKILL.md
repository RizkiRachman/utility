---
name: observability-and-instrumentation
description: Logging, metrics, tracing, alerting, and SLI/SLO observability patterns for the goods-price-comparison service. Practical guidance using Micrometer, Prometheus, Logstash, and MDC correlation.
---

# Observability & Instrumentation

## Overview

Observability is how you understand what your system is doing without shipping new code to find out. This project has **structured JSON logging** (LogstashEncoder), **Micrometer + Prometheus** metrics, and **MDC correlation IDs** already wired. The gap is **distributed tracing** — spans are not yet instrumented, and `@Async` executors do not propagate MDC context.

This skill covers all three pillars, the SLI/SLO framework that connects them to business value, and the project-specific tooling you have today.

---

## The Three Pillars

```
┌─────────────────────────────────────────────────────────────┐
│                     OBSERVABILITY                            │
├──────────────┬──────────────────┬────────────────────────────┤
│   METRICS    │     TRACES       │          LOGS              │
│  What?       │    Where?        │         Why?               │
│              │                  │                            │
│  • Request   │  • Span per op   │  • Structured JSON         │
│    rate      │  • Latency per   │  • Correlation IDs         │
│  • Error     │    service       │  • Stack traces            │
│    rate      │  • Async chain   │  • Request context         │
│  • Latency   │  • DB query      │  • Error details           │
│    p50/p99   │    timing        │                            │
└──────────────┴──────────────────┴────────────────────────────┘
```

| Pillar | Answers | Primary Tool | Cost |
|--------|---------|-------------|------|
| **Metrics** | Is something wrong? | Prometheus + Micrometer | Cheap, always on |
| **Traces** | Which step failed? | Micrometer Observation | Moderate, sampling |
| **Logs** | Why did it fail? | Logstash + MDC | Expensive, needs indexing |

**Order of operations during an incident**: Metrics → Traces → Logs. Never start with logs.

---

## SLI/SLO Framework

### Definitions

| Term | Meaning | Example |
|------|---------|---------|
| **SLI** (Service Level Indicator) | A raw measurement of a service property | Request latency p99, error ratio |
| **SLO** (Service Level Objective) | A target threshold for an SLI over a window | 99.5% of requests < 500ms (30d rolling) |
| **Error Budget** | The allowed failure within the SLO window | 0.5% of 30d requests = ~21 minutes of downtime |

### Project SLIs (Suggested)

| SLI | Indicator | Source |
|-----|-----------|--------|
| Availability | `http_server_requests_seconds_count{status=~"5.."} / total` | Micrometer |
| Latency | `http_server_requests_seconds{status="2xx"}` p99 | Micrometer |
| LLM Extraction Success | `llm_extraction_success_total / llm_extraction_total` | Custom counter |
| Receipt Processing | Time from `ReceiptUploadedEvent` → price calc complete | Trace timing |
| DB Query Performance | `hikaricp_connections_timeout_total` | Micrometer + Postgres MCP |

### Error Budget Policy

```
SLO: 99.5% latency p99 < 500ms over 30 days
Error budget: 0.5% × (30 × 24 × 60) = ~21.6 minutes

Budget consumption:
  • 5xx spike: 3 mins of errors = 14% budget spent
  • Budget at 80% → Review (why are we burning budget?)
  • Budget at 100% → All hands on deck, freeze feature releases
```

**Rule**: Don't burn your error budget on alerts that wake people up but don't matter. If p99 latency drifts from 200ms to 300ms over a week, that's a trend, not an incident.

---

## Logging Patterns

### Current Project Setup

The project uses **LogstashEncoder** for JSON structured logging. Every log line produces:

```json
{"@timestamp":"2026-06-16T10:00:00Z", "level":"INFO", "logger":"c.e.g.price.PriceService",
 "message":"Price updated: id=42, price=12.99", "correlationId":"a1b2c3d4",
 "traceId":"...", "spanId":"...", "service":"goods-price-comparison"}
```

**Already configured** (`logback-spring.xml`):
- Console + Rolling file appenders (500MB/file, 30 days, 10GB cap)
- MDC fields: `correlationId`, `traceId`, `spanId` (ready for tracing)
- `traceId`/`spanId` are **plumbed but empty** — tracing instrumentation not yet active

### Log Level Guide

| Level | When to Use | Current Usage in Project |
|-------|-------------|--------------------------|
| `ERROR` | Something is broken, needs human action | Price calc failures, LLM provider errors, scheduled job failures |
| `WARN` | Degraded path, fallback used, unexpected state | Cache miss fallback, null field default, unbounded `findAll()` call |
| `INFO` | Significant lifecycle event | Service start, job trigger/complete, entity create/update |
| `DEBUG` | Active debugging only, never on in production | Method entry/exit, transformation results, parsing fallback |
| `TRACE` | Very granular (DB query params, loop iterations) | Hibernate SQL bindings in `local` profile only |

### Logging Conventions (from `@Slf4j` usage)

```java
// GOOD — parameters, not string concatenation
log.info("Product created: {} (id: {})", saved.getName(), saved.getId());

// GOOD — pass the full exception (not .getMessage())
log.error("Failed to process receipt {}: {}", receiptId, event, exception);

// GOOD — WARN for recoverable, not ERROR
log.warn("Cache miss for productId={}, falling back to DB", productId);

// BAD — concatenation creates garbage, skips parameterized check
log.info("Price updated: " + id);  // ← Don't do this
```

### Correlation ID Propagation

The `CorrelationFilter` sets `correlationId` in MDC at every HTTP request boundary. Propagate it when calling external services:

```java
// Already done in AbstractRestLlmProvider:
var correlationId = MDC.get("correlationId");
if (correlationId != null) {
    headers.set("X-Correlation-ID", correlationId);
}
```

### MDC Propagation in @Async (Known Gap)

**Current state**: The project's `ThreadPoolTaskExecutor` beans do **not** configure MDC propagation. If thread A sets MDC before calling an `@Async` method, the async thread B won't see it.

**Fix for each executor (add to `AsyncConfiguration`)**:

```java
executor.setTaskDecorator(runnable -> {
    var mdc = MDC.getCopyOfContextMap();
    return () -> {
        var previous = MDC.getCopyOfContextMap();
        if (mdc != null) MDC.setContextMap(mdc);
        try { runnable.run(); } finally {
            if (previous != null) MDC.setContextMap(previous);
            else MDC.clear();
        }
    };
});
```

Without this, correlation IDs break across `@Async("receiptProcessorExecutor")`, `@Async("activityLogExecutor")`, and `@Async("receiptApproveProcessorExecutor")` boundaries.

---

## Metrics

### Already Configured

- `micrometer-registry-prometheus` on classpath
- `/actuator/prometheus` endpoint exposed
- JVM metrics: memory, threads, GC, classes loaded — auto-instrumented by Micrometer

### Counters vs Histograms

| Type | What | When to Use | Example |
|------|------|-------------|---------|
| **Counter** | Monotonically increasing value | Count events | `llm_extraction_attempts_total` |
| **Gauge** | Single numeric value that goes up and down | Current state | `active_receipt_processing` |
| **Timer** | Duration + count of events | Latency tracking | `price_calculation_duration_seconds` |
| **DistributionSummary** | Size distribution of events | Payload size | `receipt_image_bytes` |

### Key Micrometer Meters

```java
// In any @Service or @Component:
private final MeterRegistry meterRegistry;

// Counter — count occurrences
meterRegistry.counter("price.calculation.attempts", "storeId", storeId).increment();

// Timer — measure latency
var sample = Timer.start(meterRegistry);
try {
    return doExpensiveCalculation(input);
} finally {
    sample.stop(Timer.builder("price.calculation.duration")
        .tag("storeId", storeId)
        .publishPercentiles(0.5, 0.95, 0.99)
        .register(meterRegistry));
}

// Gauge — expose current queue depth
meterRegistry.gauge("receipt.processing.queue.depth", tags, queue, Collection::size);
```

### Spring Boot Auto-Configured Meters

| Metric | Description | Labels |
|--------|-------------|--------|
| `http_server_requests_seconds` | HTTP request latency | `method`, `status`, `uri`, `outcome` |
| `jvm_memory_used_bytes` | Heap + non-heap used | `area`, `id` |
| `jvm_gc_pause_seconds` | GC pause time | `action`, `cause` |
| `hikaricp_connections_active` | Active DB connections | `pool` |
| `logback_events_total` | Log events by level | `level` |
| `spring_data_repository_invocations_seconds` | Repository method latency | `repository`, `method` |

### Custom Metrics Plan (Suggested)

```
llm_extraction_attempts_total     — counter, tags=[provider, model, success]
llm_extraction_duration_seconds   — timer, publishPercentiles=[0.5, 0.95, 0.99]
receipt_processing_duration       — timer (from event received → price calc complete)
price_cache_hit_ratio             — gauge (hitCount / (hitCount + missCount))
```

---

## Tracing

### Current State

The project has `traceId` and `spanId` MDC keys configured in `logback-spring.xml` but **no tracing instrumentation**. These fields are empty in logs until tracing is enabled.

### Adding Micrometer Observation (How-To)

Spring Boot 3.4 uses Micrometer Observation as its tracing API. Add the dependency:

```xml
<dependency>
    <groupId>io.micrometer</groupId>
    <artifactId>micrometer-tracing-bridge-brave</artifactId>
</dependency>
```

Then annotate any bean method:

```java
import io.micrometer.observation.annotation.Observed;

@Observed(name = "price.calculation", contextualName = "calculate-best-price")
public PriceCalculationResult calculateBestPrice(ProductId productId) {
    // Span automatically created, traced, and timed
}
```

The span appears in logs as `traceId` and `spanId` in MDC, and appears in the metric as `price.calculation` timer.

### @Observed Configuration

```java
@Configuration
public class ObservationConfig {
    @Bean
    ObservationRegistry observationRegistry() {
        return ObservationRegistry.create();
    }
}
```

### Tracing Across @Async

When `@Observed` wraps an `@Async` method, the trace propagates through the executor only if:

1. The `TaskExecutor` has a `TaskDecorator` that propagates the observation context (same MDC pattern above)
2. The `ObservationRegistry` is **thread-scoped** (default) — must be passed via decorator

### Tracing Across HTTP Calls (RestTemplate)

```java
// Auto-configured when micrometer-tracing-bridge-brave is on classpath:
// RestTemplate interceptors propagate trace context via B3 headers
restTemplate.getForObject(url, Response.class);
// Outgoing request gets: X-B3-TraceId, X-B3-SpanId, X-B3-Sampled headers
```

### What to Observe

| Method | Observation Name | Reasoning |
|--------|-----------------|-----------|
| `PriceService.calculateBestPrice()` | `price.calculation` | Core domain operation |
| `ReceiptUploadedEventHandler.doExecute()` | `receipt.processing` | Event-driven flow entry |
| `ShoppingOptimizer.optimize()` | `shopping.optimization` | Cross-domain aggregation |
| `LlmService.extractReceiptData()` | `llm.extraction` | External dependency call |

---

## Alerting

### When to Alert

```
CRITICAL    — pagerduty/PagerDuty alert, wake someone up
              • Error rate > 5% for 5 minutes (gateway errors)
              • p99 latency > 2s for 10 minutes
              • Receipt processing backlog > 1000 unprocessed
              • Application down (liveness probe fails)

WARNING     — Slack/email, next-business-day review
              • Error rate > 1% for 15 minutes
              • p99 latency > 1s for 30 minutes
              • Pool exhausted (HikariCP connections = max)
              • Budget burned > 70% in a week

INFO        — Dashboard, no notification
              • Deploy succeeded
              • Config change detected
              • Batch job completed
              • Rate limit threshold approaching
```

### Alert Fatigue Prevention

| Rule | Why |
|------|-----|
| Alert on **symptoms**, not causes | "Error rate > 5%" not "Disk > 80%". Disk fills are a cause; the symptom is errors. |
| No alert without a **runbook** | If the on-call can't fix it in 15 minutes, the alert is noise. |
| Silence known issues | A known bug that generates hourly alerts is a management failure, not an observability problem. |
| Burn rate alerts | Alert when error budget is burning faster than expected (e.g., 5% error rate for 10 mins = budget for 24h gone in 10 mins). |

### Runbook Template for Common Alerts

```
ALERT: High error rate on /api/v1/prices endpoint

1. CHECK METRICS: http_server_requests_seconds{uri="/api/v1/prices", status="5xx"}
   - Is it one status code (503 = overload, 500 = bug)?
2. CHECK LOGS: grep for "correlationId" of failing requests
   - Same input causing all failures? Null product ID?
3. CHECK DB: Postgres MCP
   - `pg_readonly("SELECT count(*) FROM prices WHERE product_id IS NULL")`
   - `pg_readonly("SELECT * FROM pg_stat_activity WHERE state = 'active'")`
4. CHECK DEPLOY: Was a new version deployed recently?
   - lean-ctx: trace what changed in the price flow
5. RESPONSE: Rollback, feature flag, or hotfix?

ESCALATION: If unresolved after 15 minutes, escalate to senior engineer.
```

---

## Tooling: Observability via MCP Tools

### Postgres MCP — Query Performance

When metrics show slow DB queries, drill into the database directly:

```json
// Find slow queries
{"name": "postgres_pg_top_queries", "arguments": {}}

// Check for missing indexes
{"name": "postgres_pg_seq_scan_tables", "arguments": {}}

// Inspect schema for column-level issues
{"name": "postgres_pg_describe_table", "arguments": {"table": "prices"}}

// Check connection pool health
{"name": "postgres_pg_health", "arguments": {}}
```

### lean-ctx — Flow Tracing for Performance

When investigating a slow execution flow, trace it end-to-end:

```json
// Find the execution flow
{"name": "ctx_compose", "arguments": {"query": "receipt processing end to end", "task_context": "performance investigation"}}

// Check blast radius of a suspected bottleneck
{"name": "ctx_impact", "arguments": {"target": "PriceBatchProcessor.processBatch", "direction": "upstream"}}

// Full context on a suspect method
{"name": "ctx_compose", "arguments": {"name": "ShoppingOptimizer.optimize", "include_content": true}}
```

### Log-Based Queries with lean-ctx

```bash
# Find all error logging patterns in the price domain
lean-ctx ctx_search --pattern "log\.error.*[Pp]rice" --ext ".java" --path src/main

# Find MDC usage — where correlation IDs are propagated
lean-ctx ctx_search --pattern "MDC\.(get|put|setContextMap)" --ext ".java"

# Find all @Observed usage (will be empty until tracing is added)
lean-ctx ctx_search --pattern "@Observed" --ext ".java"
```

---

## Verification Checklist

When adding observability to a component:

- [ ] Logs: Entry/exit with key parameters at DEBUG level
- [ ] Logs: ERROR for failures with full exception, not `.getMessage()`
- [ ] Logs: MDC correlation ID propagated through async boundaries
- [ ] Metrics: At least one counter and one timer per domain operation
- [ ] Metrics: Tags are bounded (no unique user IDs as tag values)
- [ ] Tracing: `@Observed` on the entry point method
- [ ] Alerting: Runbook exists for any new alert rule
- [ ] Alerting: Alert threshold has a rationale (not arbitrary)
- [ ] Tested: Metrics appear at `/actuator/prometheus`
- [ ] Tested: Logs are valid JSON (no malformed output)

## Red Flags

- A log line with string concatenation instead of parameterized `{}` placeholders
- A metric tag with unbounded cardinality (user IDs, timestamps, random values)
- An alert rule with no runbook or escalation path
- `try { ... } catch (Exception e) { log.error("...") }` that swallows without rethrowing
- `@Observed` on `@Async` without `TaskDecorator` for MDC/Observation propagation
- Logging at INFO level in a hot loop (every request, every loop iteration)

## Interaction with Other Skills

- **`systematic-debugging`**: Uses observability data (pillars section) as the first step in the scientific debugging loop. The "Observability section" in that skill aligns directly with this one.
- **`qa-expert`**: SLO burn rate is a quality metric. Validate SLO targets during code review.
- **`lean-ctx-debugging`**: Trace execution flows to find where instrumentation is missing.
- **`security-expert`**: Ensure no sensitive data in log fields (passwords, tokens, PII) — redact in WARN/ERROR too.
