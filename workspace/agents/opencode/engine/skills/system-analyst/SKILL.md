---
name: system-analyst
description: System analysis — architecture evaluation, dependency mapping, impact analysis, and technical documentation
license: MIT
compatibility: opencode
tags:
  - architecture
  - impact-analysis
  - dependency-mapping
  - system-design
file_patterns:
  - "**/*.java"
metadata:
  role: analyst
  domain: systems
triggers:
  - "architecture"
  - "impact analysis"
  - "dependency"
  - "entry points"
  - "data flow"
---

# System Analyst

## Project Architecture

### Hexagonal Structure (per service)

```text
application/                  # Pure Java, no Spring/JPA

├── domain/model/             # @Builder @Getter @Setter

├── domain/service/           # Implements *InPort, publishes via *EventOutPort

└── port/in/, port/out/       # Driving (*InPort) / driven (*RepositoryPort, *EventOutPort) ports

infrastructure/               # Adapters (Spring/JPA)

├── adapter/web/              # REST controllers, DTO mappers

├── adapter/persistence/      # JPA entities, *RepositoryAdapter implements *RepositoryPort

└── adapter/event/ + handler/event/  # *EventAdapter → Publisher → @Async @TransactionalEventListener

```
### Dependency Flow

```text
Controller → WebAdapter → *InPort → DomainService → *RepositoryPort → *RepositoryAdapter → JPA

                                                       ↘ *EventOutPort → EventAdapter → Publisher → EventHandler

```
**Key rule**: `application/` never imports `infrastructure/`. Enforced by 7 ArchUnit rules.

### Concrete Event Flow

```text
ReceiptService → ReceiptEventOutPort → ReceiptEventAdapter → ApplicationEventPublisher

    → ReceiptCorrectedPriceCalcHandler (@Async @TransactionalEventListener)

```
## Analysis Patterns

- **Entry points**: controllers, event handlers, scheduled tasks. Trace one complete lifecycle end-to-end.

- **Impact**: use `ctx_impact({target, direction: "upstream"})`. Consider schema, API contracts, event format changes.

- **Architecture checks**: dependency direction correct? Components independently testable? No JPA annotations in domain? No `OneToMany`/`JoinColumn` — FK columns are `Long storeId`. Ports return nullable, never `Optional<T>`.

- **Document decisions**, not code. Diagrams at orientation level, not implementation detail.

---

## Evolutionary Architecture

Architecture is not a static blueprint — it evolves under pressure from new requirements,
scale, and learned constraints. This section covers how to **treat architecture as a
hypothesis** and validate it with automated checks, coupling analysis, and impact
assessment. All examples are grounded in this project's patterns.

### Fitness Functions — Automated Architecture Governance

A **fitness function** is an automated check that measures how close the system is to an
architectural goal. When the function fails, architecture has drifted and needs
correction. This project already runs **7 fitness functions** every `mvn test` via
`HexagonalArchitectureTest`:

| # | Fitness Function | What It Guards | Architecture Characteristic |
|---|-----------------|----------------|----------------------------|
| 1 | `domainMustNotDependOnInfrastructure` | Domain purity — `application/` never imports `infrastructure/` | Modifiability, testability |
| 2 | `domainModelsMustNotHaveJpaAnnotations` | No `@Entity`, `@Table`, `@Column`, `@Id` in `..domain.model..` | Portability, testability |
| 3 | `portsMustNotReturnOptional` | Ports return nullable (never `Optional<T>`) — `..port..` public methods | API stability, simplicity |
| 4 | `entitiesMustNotUseJpaRelationshipAnnotations` | No `@OneToMany`, `@ManyToOne`, `@JoinColumn`, etc. FK as primitives | Modifiability, DB schema freedom |
| 5 | `layeredArchitectureShouldRespectHexagonalBoundaries` | Domain → Ports → Infrastructure layering; infra may not be accessed | Modifiability |
| 6 | `domainServicesMustBeAnnotatedWithService` | All `..domain.service..` classes ending in `Service` must be `@Service` | Consistency, DI correctness |
| 7 | `repositoryAdaptersMustBeAnnotatedWithComponent` | All `RepositoryAdapter` classes must be `@Component` | Consistency, DI correctness |

Additionally, the `ObjectUtils` sealed-methods test acts as a **versioned contract fitness
function** — it prevents uncontrolled growth of shared utility code.

**Pattern for new fitness functions**: When adding a new architectural constraint, write
it as a JUnit 5 test in `HexagonalArchitectureTest.java` and annotate with `@Test`.
This keeps governance close to the code, runs in CI, and is visible to all agents.

### Architecture Characteristics — Measurable Properties

The system optimizes for five key characteristics. Each must be measurable:

1. **Testability** (primary driver of hexagonal architecture)
   - Metric: ArchUnit passes (7/7), JaCoCo ≥80% INSTRUCTION + BRANCH
   - Enablers: Domain pure Java (no Spring), `@ActiveProfiles("test")` with H2,
     Flyway disabled in tests, `Testcontainers` for integration tests
   - Risk indicator: A change that requires running the full app to verify

2. **Modifiability**
   - Metric: Days to add a new service domain (target: <1 day using existing patterns)
   - Enablers: Event-driven decoupling (`ApplicationEvent` + `@Async`), port-based
     contracts, no cross-service table joins, FK as primitives
   - Risk indicator: Two services changing in the same PR (see Change Coupling below)

3. **Scalability**
   - Metric: Event handler throughput under load
   - Enablers: `@Async("receiptProcessorExecutor")` with dedicated thread pools,
     `@TransactionalEventListener(AFTER_COMMIT)` for at-least-once delivery,
     stateless domain services
   - Risk indicator: Synchronous cross-service calls in a request path

4. **Security**
   - Metric: Rate-limited endpoints (currently via `@RateLimit` annotation + interceptor),
     input validation at web adapter boundary
   - Enablers: `GlobalExceptionHandler` (404/400/500 mapping), `RateLimitInterceptor`
     with token-bucket algorithm, HTTP header constants (`X-RateLimit-Limit`,
     `X-RateLimit-Remaining`)
   - Risk indicator: New endpoint without `@RateLimit` or input validation

5. **Consistency**
   - Metric: Spotless (Google Java Style) + SpotBugs + PMD CPD pass on every build
   - Enablers: Build gates in `pom.xml`, automated formatting at `mvn spotless:apply`
   - Risk indicator: Formatting-only diffs in PRs (means spotless wasn't run)

**When evaluating a change**, ask: which of these 5 characteristics does it affect?
If it weakens one without strengthening another, the tradeoff needs justification.

### Change Coupling Analysis

Files that **historically change together** may share a hidden dependency. When two files
in different service domains change in the same commit, it often means the service
boundary is wrong or an abstraction is missing.

#### Detecting Change Coupling

```bash
# Find files that changed most frequently (top 30)
  sort | uniq -c | sort -rn | head -30

# Find pairs that changed together in the same commit
  awk '{if (NR%2==1) commit=$1; else print commit, $0}' | \
  sort | uniq -c | sort -rn | head -50
```

#### Interpreting Coupling

| Pattern | Interpretation | Action |
|---------|---------------|--------|
| `ReceiptService.java` ↔ `PriceService.java` | Expected — receipt processing triggers price calculation | Ensure event boundary is clear, not shared mutable state |
| `StoreAdapter.java` ↔ `ProductAdapter.java` | Suspicious — stores and products have different lifecycles | Extract shared logic into `common/` |
| Any domain model ↔ its JPA entity simultaneously | Expected — model changes often require entity changes | Check mapper is updated |
| Two event handlers in different domains | Investigate — events should be independent consumers | Consider an orchestrating domain service |

the same commit frequently, it suggests receipt logic is reaching into store data
directly instead of going through ports and events.

#### Weekly Coupling Health Check

```bash
# Count commits that touch more than one service domain
  grep -E '^(receipt|store|product|price|shopping|llm|alert|activity|system)/' | \
  sort | uniq -c | sort -rn | head -20
```

If a commit touches `receipt/` AND `price/` AND `product/` files, review whether
the event flow is properly decoupled or if synchronous calls have leaked in.

### Evolutionary Database Design

Database schema evolves **alongside code**, not ahead of it. Flyway migrations are the
mechanism; this project uses three migration directories:

```
db/migration/tables/     # CREATE TABLE, CREATE INDEX (DDL for new entities)
db/migration/alter/      # ALTER TABLE, ADD COLUMN (schema evolution)
db/migration/data/       # INSERT, UPDATE static/reference data
```

#### Migration Patterns

**Expand-Contract** (zero-downtime schema changes):
1. **Expand**: Add nullable column via `ALTER TABLE ... ADD COLUMN ...`
2. **Migrate**: Backfill data for existing rows (application code handles both states)
3. **Contract**: Make column `NOT NULL`, remove old column references

Example:
```sql
-- V2__add_store_region.sql (tables/)
ALTER TABLE stores ADD COLUMN region VARCHAR(50);

-- V3__backfill_store_region.sql (data/)
UPDATE stores SET region = 'unspecified' WHERE region IS NULL;

-- V4__store_region_not_null.sql (alter/)
ALTER TABLE stores ALTER COLUMN region SET NOT NULL;
```

**Add nullable → Populate → NOT NULL**:
- Step 1: `ADD COLUMN` nullable in `alter/`
- Step 2: Backfill in `data/` (application writes to new column going forward)
- Step 3: `ALTER COLUMN SET NOT NULL` in a later `alter/` migration
- Code never deploys assuming NOT NULL until step 3 is applied

**View-based abstraction**: When renaming a table or splitting a column, create a
view with the old name that returns the new schema. Application code moves to the
new table; the view supports rollback. Drop the view after N releases.

#### Testing Migrations

```bash
# Flyway is disabled in test profile (@ActiveProfiles("test"))
# Use @Testcontainers with a real PostgreSQL for migration testing:
#   @Container static PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:16")
```

Run `mvn flyway:migrate -P flyway` against a local PostgreSQL to validate migrations
before deploying.

### Risk Analysis with Impact Assessment

For any proposed change, run this 4-step assessment **before** implementation:

#### Step 1: Identify Affected Architecture Characteristics

Using the 5 characteristics above, ask:
- **Testability**: Does this change add infrastructure coupling to domain logic?
- **Modifiability**: Does it create a new cross-service dependency?
- **Scalability**: Does it add synchronous work to an async handler?
- **Security**: Does it expose a new endpoint without `@RateLimit`?
- **Consistency**: Does it introduce a new pattern inconsistent with existing code?

#### Step 2: Check Fitness Functions

Run `mvn test` early (before the implementation is complete) to verify no existing
fitness function breaks. If you must violate a fitness function temporarily:
1. Document exactly which test fails and why
2. Plan the follow-up commit that restores it
3. The intermediate state should never reach `main`

#### Step 3: Assess Change Coupling History

```bash
  sort | uniq -c | sort -rn | head -10
```

If the file you're changing historically appears alongside files in other domains,
verify your change doesn't introduce a hidden coupling.

#### Step 4: Determine Schema Evolution Path

| Change Type | Migration Strategy | Code Handling |
|-------------|-------------------|---------------|
| New entity table | `CREATE TABLE` in `tables/` | New domain model + entity + mapper |
| New nullable column | `ALTER TABLE ADD COLUMN` in `alter/` | read handles null, write populates |
| New required column | Expand → backfill → contract (3 migrations) | Write new column, read uses old until contract |
| Remove a column | Mark deprecated in code first, remove in N releases | `@Deprecated` annotation, then migration to drop |
| Rename a column | Add new + copy data + drop old (view for rollback) | Read both, write new, then remove old read |

#### Decision Matrix

| Testability Risk | Modifiability Risk | Coupling Found | Schema Impact | Decision |
|-----------------|-------------------|----------------|---------------|----------|
| Low | Low | No | None | Proceed (standard change) |
| Low | Low | No | Additive | Proceed with migration |
| Medium | Low | No | None | Proceed, add fitness function |
| High | Any | Yes | Any | **Stop** — redesign boundary first |
| Any | High | Yes | Breaking | **Stop** — needs architecture review |

**When to escalate**: If the change scores High/Any/Yes/Any or Any/High/Yes/Breaking,
delegate to `@council` for an architecture review before implementation. The cost of
fixing a wrong boundary after deployment is 10x the cost of getting it right.

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

