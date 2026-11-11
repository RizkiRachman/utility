---
name: shipping-and-launch
description: End-to-end release orchestration - pre-launch verification, canary rollout, rollback planning, post-deploy smoke tests, and stakeholder communication. Invoked by the orchestrator orchestrator when contract.state transitions to EXECUTE_SCORED → REVIEW, and feeds into COMPLETE.
---

# Shipping & Launch

Take verified code to production safely. This skill covers **what to check before launch, how to roll out gradually, and how to roll back when things go wrong.** It assumes implementation and review (ArchUnit, SpotBugs, tests) are already complete - this is the **last mile**.

> **Pre-flight**: Load the orchestration envelope first (`lean-ctx ctx_knowledge recall --query "orchestration-contract:<task_id>"`). The `decisions.*`, `governance.*`, and `outputs.code_changes[]` fields determine what needs release verification.
>
> **Prerequisite**: All EXECUTE and REVIEW phase scoring must pass (≥70). Run `mvn verify` and confirm zero SpotBugs/PMD/ArchUnit failures before any launch step.

---

## 1. Pre-Launch Checklist

Run this checklist **in order** before any deployment reaches production. Every check must pass; if any fails, resolve before proceeding.

```text
□ 1. ENV VARS - All new environment variables (DB URLs, API keys, feature flags)
     are documented in `.env.example` and set in all target environments
     (staging, canary, production). No hardcoded secrets.
□ 2. MIGRATIONS - All Flyway/Liquibase scripts are idempotent (repeatable).
     Down-migration scripts exist for every up-migration. Tested against
     a production-sized dataset for performance impact.
□ 3. FEATURE FLAGS - Every significant behavior change is gated behind a
     feature flag with a known owner and deprecation date. Flags default OFF
     in production.
□ 4. MONITORING - New dashboards or alert rules exist for key metrics
     (error rate, latency p99, throughput). Baselines recorded from staging.
□ 5. BACKWARDS COMPAT - API versioning strategy is decided (see §2.2).
     No breaking changes without a co-existing v2 endpoint.
□ 6. DEPENDENCIES - No unresolved CVEs in new or updated dependencies
     (run `mvn verify -P security-check`).
□ 7. HEALTH ENDPOINTS - `GET /actuator/health`, `GET /actuator/info`,
     and any custom readiness/liveness probes are functional.
□ 8. BUILD ARTIFACT - `mvn clean verify` passes. JAR/WAR is reproducible
     (same commit = same checksum).
□ 9. STATE.MD - Updated with release scope, known risks, and rollback contact.
□ 10. ORCHESTRATION CONTRACT - `outputs.agent_reports[]` includes the
      quality-analyst's REVIEW score ≥70.
□ 11. HUMANIZER - User-facing docs shipped this release (README, changelog,
      release notes, PR description) pass `/skill humanizer`. Docs still
      carrying AI patterns (em dashes, rule-of-three, promotional tone) are
      not done. Internal state files (`session/state.md`, contract JSON,
      code comments) exempt.
```

### Decision Matrix: Pre-Launch Blockers

| If this check fails... | Severity | Action |
|------------------------|----------|--------|
| Env var missing in prod | CRITICAL | BLOCK - do not deploy. Raise infra ticket. |
| Migration not idempotent | CRITICAL | BLOCK - rewrite migration, re-test. |
| Feature flag defaults ON | HIGH | Set default to OFF. Verify with a staging deploy. |
| No monitoring for new metric | HIGH | Add alert/dashboard before proceeding. |
| Breaking API change, no version | CRITICAL | BLOCK - add co-existing version or postpone. |
| CVE in new dependency | CRITICAL | BLOCK - patch or swap dependency. |

---

## 2. Rollback Plan

Every release must have a rollback strategy **defined before deployment**, not during an incident.

### 2.1 Database Migration Rollback (Expand-Contract)

Use the **expand-contract pattern** for zero-downtime schema changes:

```
Phase 1 - EXPAND (deploy N):
  ┌──────────────┐    ┌───────────────┐    ┌─────────────────┐
  │ Add new column│    │ Dual-write    │    │ Backfill data   │
  │ /new table   │ →  │ (old + new)   │ →  │ from old → new  │
  └──────────────┘    └───────────────┘    └─────────────────┘
  All code reads FROM old column. Writes go TO both.

Phase 2 - MIGRATE (deploy N+1):
  ┌───────────────┐    ┌──────────────┐
  │ Switch reads   │    │ Remove dead  │
  │ to new column  │ →  │ writes to old│
  └───────────────┘    └──────────────┘

Phase 3 - CONTRACT (deploy N+2, after validation):
  ┌─────────────────┐
  │ Drop old column │
  │ /old table      │
  └─────────────────┘
  Rollback at Phase 2 or 3 is a *code revert only* - no DB undo needed.
```

**Rollback at each phase**:

| Phase | Rollback cost | Rollback action |
|-------|--------------|-----------------|
| EXPAND (N) | Low | Revert code. New column stays unused. |
| MIGRATE (N+1) | Medium | Revert code. Old column still has data. |
| CONTRACT (N+2) | High | Restore dropped column from backup. Test first. |

**Rule**: Never drop a column in the same deploy that switches reads. Wait at least one full deploy cycle.

### 2.2 API Versioning

| Strategy | When to use | Rollback |
|----------|-------------|----------|
| **URL path versioning** (`/v1/`, `/v2/`) | Breaking changes, public API | Old version still live - revert new version's routing |
| **Header versioning** (`Accept: vnd.app.v2+json`) | Internal/microservice APIs | Same as URL, but needs gateway config revert |
| **Backwards-compatible expansion** | Adding fields only | No version change needed - rollback is a code revert |

**Kill-switch for feature flags**:

```text
Every feature flag must be:
  □ Removable in a single deploy (no hard dependencies)
  □ Default OFF in production
  □ Monitored: if flag=ON variant degrades metrics, set flag=OFF immediately
  □ Documented: owner, purpose, expected deprecation date
```

### 2.3 Feature Flag Kill-Switch Protocol

```text
Metrics degrade? (error rate > 1% increase OR p99 latency > 2x baseline)
  ├── Yes, and feature flag exists → Set flag to OFF. No code revert needed.
  │     └── Monitor for 5 minutes. If stable → incident resolved.
  ├── Yes, but no feature flag → Code revert required.
  │     ├── Revert the commit.
  │     ├── Re-deploy previous artifact.
  │     └── Run smoke tests (§4.1).
  └── No → Continue monitoring. Flag stays ON.
```

---

## 3. Canary Deployment

Gradual rollout with automated gates. Every release should hit **staging → canary → production** in sequence.

### 3.1 Stages

| Stage | Traffic % | Duration | Pass criteria | Action on fail |
|-------|-----------|----------|---------------|----------------|
| Staging | 0% (internal) | 1 cycle | `mvn verify` + smoke tests pass | Fix and re-deploy |
| Canary | 5% | 30 min | Error rate ≤ baseline × 1.1 | Auto-rollback |
| Ramped | 25% | 2h | Latency p99 ≤ baseline × 1.2 | Auto-rollback |
| Ramped | 50% | 2h | No alert triggers | Manual approval |
| Full | 100% | - | All checks pass | Release complete |

### 3.2 Metrics Comparison

Compare **canary** vs **baseline** (previous stable release) on these metrics:

| Metric | Auto-rollback threshold | Measurement window |
|--------|------------------------|-------------------|
| HTTP 5xx rate | > baseline × 1.5 (or > 1% absolute) | 5 minute rolling |
| p99 latency | > baseline × 1.5 | 5 minute rolling |
| Throughput drop | < baseline × 0.8 | 5 minute rolling |
| Business metric (e.g., conversion) | > baseline × 0.95 | 15 minute rolling |
| Error budget burn rate | > 10% per hour | 1 hour |

### 3.3 Auto-Rollback Flow

```text
[Canary metrics poll]
    │
    ├─ All green → Advance to next stage
    │
    └─ Threshold breached → Initiate auto-rollback
         │
         ├─ 1. Set feature flag OFF (if gated)
         ├─ 2. Route traffic to previous version
         ├─ 3. Send alert to #release channel
         ├─ 4. Log deployment: CANARY_ROLLBACK - <reason>
         └─ 5. Do NOT auto-retry. Require human investigation.
```

---

## 4. Release Verification

After every deployment (including rollbacks), run these verifications.

### 4.1 Post-Deploy Smoke Tests

```text
□ 1. Health check - GET /actuator/health returns 200
□ 2. Readiness - GET /actuator/health/readiness returns 200
□ 3. Core flow - Execute the primary user journey (e.g., create receipt → price comparison)
□ 4. Auth flow - Token acquisition and validation works
□ 5. Error handling - 404 on unknown resource returns correct shape
□ 6. Event flow - If async events are part of the release, verify handler completed
```

Run via curl or a dedicated smoke-test job in CI. Never skip smoke tests for production deploys.

### 4.2 Synthetic Monitoring

Configure synthetic monitors for the post-deploy window (first 24h):

| Check | Frequency | Action on failure |
|-------|-----------|-------------------|
| `/actuator/health` | 30s | Alert on-call |
| Core flow (multi-step) | 5 min | Alert + page |
| Latency budget (< 2s p99) | 1 min | Alert if breached > 5 consecutive checks |
| Error rate (< 0.1% 5xx) | 1 min | Auto-rollback if > 1% for 5 min |

### 4.3 Health Check Decision Matrix

```
Health endpoint fails?
  ├── Liveness fails → Pod restart. If > 3 restarts → rollback.
  ├── Readiness fails → Remove from load balancer. Investigate.
  │     └── Root cause found? → Rollback or hotfix.
  └── Both fail → Full rollback. Do NOT hotfix in production.
```

---

## 5. Communication

### 5.1 Changelog & Release Notes

Update these in the repository *before* the deploy, not after:

```text
## [1.4.0] - 2026-06-16

### Added
- Receipt line-item comparison across stores (#142)
- Price alert threshold configuration (#138)

### Changed
- Product search now returns paginated results (#145)
  - Backwards-compatible - `page` and `size` params optional, default 0/20
  - See migration guide in `/docs/migrations/product-search-pagination.md`

### Deprecated
- `GET /api/v1/products/search` (use `/api/v2/products/search`)

### Fixed
- Race condition in shopping list sync (#140)

### Security
- Upgraded jackson-databind to 2.17.2 (CVE-2024-XXXXX)

---

### Rollback Notes

| Component | Rollback command | Data risk |
|-----------|------------------|-----------|
| App artifact | `kubectl rollout undo deployment/app` | None (stateless) |
| Migration v1.4.0 | `flyway undo -schemas=public` | Medium - drops new column, existing data in old column |
| Feature flag `price-compare-v2` | Set to OFF | None |
```

### 5.2 Stakeholder Notification

```text
Notify these channels at each stage:

  ┌────────────────────────────────────────────────────────────┐
  │                    DEPLOYMENT TIMELINE                     │
  ├──────────────┬─────────────────────────────────────────────┤
  │ T-15 min     │ #release channel: "Starting deploy v1.4.0" │
  │              │ #eng channel: "Code freeze until further    │
  │              │  notice"                                   │
  ├──────────────┼─────────────────────────────────────────────┤
  │ T+0 (canary) │ #release: "Canary at 5%. Monitoring."      │
  ├──────────────┼─────────────────────────────────────────────┤
  │ T+30 min     │ #release: "Canary green. Ramping to 25%."  │
  │ (ramp start) │                                             │
  ├──────────────┼─────────────────────────────────────────────┤
  │ T+2h (full)  │ #release: "100% rollout. Smoke tests pass."│
  │              │ #eng: "Code freeze lifted."                 │
  │              │ #general: "v1.4.0 released - changelog:    │
  │              │  link"                                     │
  ├──────────────┼─────────────────────────────────────────────┤
  │ T+24h        │ #release: "Post-deploy monitoring clear.   │
  │ (all clear)  │  Release v1.4.0 is stable."               │
  └──────────────┴─────────────────────────────────────────────┘

  On rollback: Notify #release AND #general within 5 minutes.
  Include: what triggered it, impact scope, ETA for fix.
```

---

## 6. Orchestration Integration - COMPLETE State Handoff

This skill feeds into the orchestrator orchestrator's final state transition. When all launch steps are done, update the orchestration contract:

### Envelope Updates for COMPLETE Transition

| Contract field | Value after shipping |
|---------------|----------------------|
| `state` | `COMPLETE` |
| `governance.current_guidance` | `"Release v<x.y.z> deployed and verified - rollback plan defined, post-deploy monitoring active"` |
| `outputs.agent_reports[]` | Append report containing: deploy timestamp, canary stages passed, smoke test results, rollback status (none/active) |
| `score.combined` | Must be ≥ 70 (update if final scoring changed) |
| `score.verdict` | `PASS` |
| `metrics.phases_completed` | Add `"SHIPPING"` |
| `lessons_learned` | Append: any launch blockers encountered, rollback triggers, monitoring gaps discovered |

### Post-COMPLETE Handoff

```text
1. Persist: lean-ctx ctx_knowledge remember category architecture key release-<version>
     value "{version, deployed_at, canary_stages, rollback_triggered, smoke_test_result}"
2. Update STATE.md: Current Focus → "Monitoring post-release stability"
     Known Blockers → (any post-deploy issues)
3. Re-index: npx lean-ctx analyze
4. Session save: ctx_session save
```

The **learner** agent picks up from COMPLETE - it extracts lessons, gotchas, and patterns from the full release cycle for durable cross-release learning.

---

## Quick Reference Card

| Situation | Action |
|-----------|--------|
| Pre-launch env var missing | BLOCK - raise infra ticket |
| Migration not idempotent | BLOCK - rewrite and re-test |
| Canary error rate spikes | Auto-rollback, notify #release |
| Feature flag works in staging, fails in prod | Disable flag, investigate env diff |
| Health endpoint failing | Remove from LB, rollback if >3 restarts |
| Breaking API change without version | BLOCK - add co-existing version |
| Post-deploy smoke test fails | Rollback immediately |
| Stakeholder needs deploy ETA | Post to #release with stage and metrics |
| Monitoring gap discovered | Add alert, mark as lesson learned |
| COMPLETE state ready | Update contract, persist knowledge, save session |

---

*Last updated: 2026-06-16. Designed for the orchestrator orchestrator's EXECUTE_SCORED → REVIEW → COMPLETE pipeline. Works with `contract.json` state machine, `quality-analyst` review output, and `learner` post-release learning.*
