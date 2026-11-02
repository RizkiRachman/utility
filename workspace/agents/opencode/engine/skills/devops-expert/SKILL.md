---
name: devops-expert
description: DevOps — CI/CD pipelines, infrastructure as code, containerization, monitoring, and deployment strategies
license: MIT
compatibility: opencode
tags:
  - devops
  - ci-cd
  - docker
  - deployment
  - monitoring
  - infrastructure
file_patterns:
  - "**/*.yml"
  - "**/Dockerfile"
  - "**/pom.xml"
metadata:
  role: devops
  domain: infrastructure
triggers:
  - "CI/CD"
  - "deploy"
  - "infrastructure"
  - "container"
  - "monitoring"
  - "rollback"
---

# DevOps Expert

## Project-Specific Build Pipeline (run in order)

```bash
lean-ctx ctx_shell mvn spotless:apply                  # Google Java Style formatting

lean-ctx ctx_shell mvn test                            # JUnit 5 + ArchUnit (7 rules)

lean-ctx ctx_shell mvn verify                          # Full: tests + ArchUnit + SpotBugs + PMD CPD

lean-ctx ctx_shell ./scripts/check-conventions.sh      # Project conventions

lean-ctx ctx_shell mvn verify -P security-check        # OWASP dependency scan

lean-ctx ctx_shell npx newman run "postman/Goods Price Comparison Service.postman_collection.json"

```
Quality gates order: formatting → architecture → static analysis → conventions → full test → security → smoke.

## CI/CD

- Fail fast: lint before build, build before test. Build artifacts immutable and versioned (semver or commit-sha tagged).

- Every pipeline run produces a single, immutable artifact (JAR, Docker image) that is promoted through environments without rebuilding.

- Pipeline stages: `build → unit-test → static-analysis → integration-test → security-scan → container-build → push → deploy-staging → smoke-test → deploy-prod`

- Secrets injected at runtime, never baked into build artifacts.

### Rollback Strategies

**Database Migration Rollback:**
- Every migration must have a reversible `down` script. Test `migrate up` + `migrate down` in CI before deploy.
- Deploy app code **before** running irreversible migrations (e.g., column drops, table renames) — or use expand-contract pattern:
  1. **Expand**: Add new column/table (app reads both old and new)
  2. **Migrate**: Backfill data, switch app to read from new
  3. **Contract**: Remove old column/table in a later deploy
- Schema changes that are backward-compatible (add column, add table) are safe to run before app deploy. Breaking changes (rename, drop, ALTER NOT NULL) must run after.
- Flyway: `mvn flyway:undo` for in-place rollback (requires Flyway Teams or manual undo scripts). Prefer creating a forward fix rather than undoing a migration in production.

**API Versioning for Safe Rollback:**
- Prefer URL-based versioning (`/api/v2/products`) or header-based (`Accept: application/vnd.app-v2+json`) — never break existing clients on version bump.
- Support at least two concurrent API versions during rollback windows. Deprecate old versions only after confirming rollback is no longer needed (typically 2-3 deploy cycles).
- Backward-compatible changes (add field, add endpoint) never require a version bump. Breaking changes (rename field, change type, remove endpoint) always do.

**Feature Flags:**
- Decouple deploy from release. Every new feature is wrapped in a flag (boolean toggle), defaulting to `off` for production.
- Flags evaluated at runtime — enables instant kill-switch without redeploy.
- Use a lightweight flags system (launchdarkly, unleash, or a simple `@Value` + `@ConditionalOnProperty` in Spring).
- Regularly audit and purge stale flags to avoid flag debt.

## Infrastructure as Code

- All infra changes go through same review as code. State files encrypted, never committed.

## Containerization

- One process per container, distroless base images, pin versions (never `latest`).

- Stateless containers; persistence in volumes or external services.

- Liveness (alive?) vs readiness (traffic?) health checks.

## Monitoring & Observability

### Three Pillars

| Pillar | Tool | Purpose | Retention |
|--------|------|---------|-----------|
| Logs | ELK, Loki, CloudWatch | Debugging, audit, error details | 7-30 days (hot), 90 days (cold) |
| Metrics | Prometheus, Datadog, Micrometer + Grafana | Trends, SLIs, capacity planning | 30 days (high-res), 12 mo (downsampled) |
| Traces | Jaeger, Zipkin, OpenTelemetry | Request flow, latency breakdown, root cause | 7 days (sampled at 1-10%) |

### What to Monitor (The Four Golden Signals)

1. **Latency** — Time to serve a request. Track p50, p95, p99 separately. Alert when p95 exceeds SLO baseline (e.g., >500ms for API, >2s for batch).
2. **Traffic** — Request rate (RPS), concurrent connections, throughput. Correlate with deploys and marketing events.
3. **Errors** — HTTP 5xx rate, business exception rate, dead-letter queue depth. Alert on error rate >1% over 5-minute window (adjust threshold per endpoint criticality).
4. **Saturation** — CPU, memory, disk IO, connection pool usage, DB active connections. Alert at 80% usage to leave headroom.

### JVM-Specific Metrics (Spring Boot + Micrometer)

- Heap/non-heap memory usage, garbage collection pause time & frequency, thread states (runnable/blocked/waiting), HikariCP connection pool status, HTTP server request metrics.

### Alerting Thresholds (Recommended Defaults)

| Signal | Warning | Critical | Window |
|--------|---------|----------|--------|
| HTTP 5xx rate | >1% | >5% | 5 min |
| p95 latency | >500ms | >2s | 5 min |
| CPU usage | >80% | >95% | 10 min |
| Heap usage | >75% | >90% | 5 min |
| GC pause time | >200ms | >1s | 1 min |
| DB connections | >80% of pool | >95% of pool | 5 min |
| Dead-letter queue | >0 | >10 | 1 min |

### Dashboards

Maintain three dashboard tiers:

1. **Executive Dashboard** — Overall health, uptime, error budget, RPS, p99 latency. Big-picture for non-technical stakeholders.
2. **Service Dashboard** — Per-service: request rate, error rate, latency heatmaps, DB query performance, JVM memory. One dashboard per bounded context (receipt, price, product, etc.).
3. **Troubleshooting Dashboard** — Raw logs view, trace search, recent deployments, recent alerts, DQL depth. Used during incident response.

Every dashboard should be one-click accessible from the on-call runbook.

### Structured Logging

- Log in JSON format from day one. Fields: `timestamp`, `level`, `service`, `traceId`, `spanId`, `message`, `duration_ms`, `error.kind`, `error.message`.
- Always propagate `traceId` across service boundaries (via HTTP header or message header) so a single request log can be correlated end-to-end.

## Deployment

### Zero-Downtime Deployment Patterns

**Blue-Green (Atomic Switch):**
- Two identical environments (blue = live, green = standby). Deploy new version to green, smoke-test, then switch traffic by updating load balancer target or DNS.
- Rollback: switch traffic back to blue. Instantaneous, no re-deploy needed.
- Trade-off: double infrastructure cost during switch window. Best for mission-critical services where any downtime is unacceptable.

**Canary (Gradual Rollout):**
- Route a small % of traffic (e.g., 5%) to new version, monitor error rates and latency for a watch period (5-30 min), then gradually increase to 25%, 50%, 100%.
- Rollback: drain the canary instance immediately (stop routing traffic to it).
- Trade-off: slower rollout, requires traffic-routing infrastructure (e.g., service mesh, Kubernetes ingress, load balancer weighted targets). Best for high-traffic services where blast radius must be limited.

**Rolling Update (Sequential):**
- Replace instances one-by-one (or batch-by-batch) until all are running the new version.
- Rollback: re-run the rolling update with the previous image tag.
- Trade-off: no traffic-routing smarts needed (native to Kubernetes `Deployment` strategy). Best for internal services and batch workers where zero-downtime is nice-to-have but not critical.

**Feature Flags (Decouple Deploy from Release):**
- Deploy code dark (flag off), enable via config UI or config change at any time.
- Rollback: flip flag off — no code change needed.
- Lever: A/B test, staged rollout, instant kill-switch, per-tenant enablement.
- Trade-off: flag management overhead, stale flag cleanup discipline required.

### Deploy Checklist (Pre-Production)

```
[ ] Runbook written and tested
[ ] DB migration scripts applied to staging and verified
[ ] Health check endpoints return 200
[ ] Readiness probe configured (validates DB, downstream dependencies)
[ ] Feature flags default to off (safe default)
[ ] Rollback plan confirmed (image tag, script, or flag flip)
[ ] Monitoring dashboards verified (metrics flowing, alerts configured)
[ ] Smoke test script written and passing against staging
[ ] Canary % defined and watch period set
[ ] Runbook shared with on-call engineer
```

## Security

- Dependency scanning in CI (`mvn verify -P security-check`), container image scanning before deploy (Trivy, Snyk, or Grype).

- Least privilege, default-deny network policies. Every service runs under its own service account with scoped IAM/role permissions.

- Secrets never in code, env vars, or config repos. Use a vault (HashiCorp Vault, AWS Secrets Manager, or Spring Cloud Config with encryption).

- TLS everywhere — including inter-service communication inside the cluster (mTLS via service mesh or cert-manager).

- Regular token/credential rotation. Audit access logs for anomalies.

## Incident Response

### Severity Levels

| Level | Definition | Response Time | Example |
|-------|-----------|---------------|---------|
| SEV-1 | Service down, data loss, security breach | <15 min, all-hands | Receipt processing completely offline |
| SEV-2 | Feature degraded, partial outage, >5% error rate | <1 hour | Price comparison slow (p95 > 5s) |
| SEV-3 | Minor impact, cosmetic, non-critical | <24 hours | Stale cache data, UI formatting issue |
| SEV-4 | Question, minor bug, no user impact | Next sprint | Typo in logs, missing metric |

### Incident Response Steps

1. **Detect** — Alert fires (or user reports issue). First responder acknowledges within SLA.
2. **Triage** — Classify severity. Determine if incident commander needs to be paged. For SEV-1/SEV-2, declare incident in the communication channel (#incidents Slack channel or on-call tool).
3. **Mitigate** — Stop the bleed. Rollback, feature flag off, scale up, block bad traffic. Fixing root cause comes **after** the service is stable.
4. **Investigate** — Once mitigated, find root cause. Check: recent deploy (revert if suspect), DB migration (rollback if recent), upstream dependency health, traffic spike, config change.
5. **Resolve** — Apply permanent fix, verify via monitoring, confirm with reporter.
6. **Postmortem** — Within 48 hours, write a blameless postmortem covering:
   - Timeline (all timestamps in UTC)
   - Detection + mitigation + resolution actions taken
   - Root cause analysis (5 Whys technique)
   - Action items with owners and deadlines
   - Monitoring gaps discovered
   - Runbook improvements needed
   - Share with team, track action items to completion

### Communication During Incidents

- One incident commander coordinates — they decide who does what. Everyone else executes.
- Status updates every 30 minutes (or more often) in the incident channel with: `What changed?`, `Current status?`, `Next action?`.
- External communication (status page, customer emails) is the incident commander's responsibility — engineers focus on technical work.
- No finger-pointing in real-time. Blameless culture. The only bad response is silence.

### Runbook Best Practices

- Every service or component has a runbook in the repo at `docs/runbooks/<service-name>.md`.
- Runbook must contain: description, health check endpoints, startup order/dependencies, common failure modes + fix steps, deploy instructions, rollback instructions, key metrics/dashboards/alert links, and on-call contact/escalation path.
- Test runbook during game days — simulate a real incident and have the on-call engineer follow the runbook without prior knowledge.

---

## Token Optimization

```bash
/skill token-optimize

```
## lean-ctx Conventions

When using this skill:

- Use `lean-ctx ctx_read` for reading files (cached, compressed, ~13 tok for unchanged files)

- Use `lean-ctx ctx_edit` for edits needing context persistence

- Use `lean-ctx ctx_shell` for all shell commands (NOT the `bash` tool — it's denied in opencode.json)

- After completing work, persist any new patterns/gotchas discovered: `lean-ctx ctx_knowledge remember category <cat> key <key> value <value>`

