---
name: release-plan
description: End-to-end release process — unit testing, quality gates (PMD, SpotBugs, Spotless, ArchUnit), PR templates, commit conventions, documentation, and token optimization
license: MIT
compatibility: opencode
tags:
  - release
  - deployment
  - pr
  - changelog
  - quality-gate
file_patterns:
  - "**/pom.xml"
  - "**/*.md"
  - "**/CHANGELOG.md"
metadata:
  role: release-manager
triggers:
  - "release"
  - "PR"
  - "quality gate"
  - "deploy"
  - "changelog"
---

# Release Plan — Goods Price Comparison Service

End-to-end workflow for shipping a clean, verified release.

---

## Phase 1: Planning

**Entry Criteria:**

- Feature request or bug report is clear and scoped

- Acceptance criteria defined and testable

- Impact analysis done (what services/contracts change)

**Deliverables:**

- Brief implementation plan (2-5 bullet points)

- List of files to change (generated via `grep`/`glob`)

---

## Phase 2: Development

**Order of Operations:**

1. Port interface — `*InPort`, `*RepositoryPort`, `*EventOutPort`

2. Domain service — implements `*InPort`, pure Java

3. Mapper — `*DtoMapper` (domain ↔ API), `*Mapper` (domain ↔ entity)

4. Adapter — web, persistence, event orchestration

5. Constants — extract magic strings to `*Constants` or enums

6. Events — domain service publishes via `*EventOutPort`, handler uses `@Async @TransactionalEventListener(AFTER_COMMIT)`

7. Tests — unit tests for domain service, adapter tests for infrastructure

---

## Phase 3: Quality Gates

Run in this order. **Fix all issues in one gate before moving to the next.**

### Gate 1: Formatting

```bash
lean-ctx ctx_shell mvn spotless:apply

```
### Gate 2: Architecture

```bash
lean-ctx ctx_shell mvn test

```
ArchUnit (7 rules) + unit tests. All must pass.

### Gate 3: Static Analysis

```bash
lean-ctx ctx_shell mvn verify

```
SpotBugs + PMD CPD. Check `config/spotbugs/exclude.xml` for suppressions.

### Gate 4: Convention Checks

```bash
lean-ctx ctx_shell ./scripts/check-conventions.sh

```
### Gate 5: Full Test Suite

All 94+ tests must pass. JaCoCo ≥90% INSTRUCTION, ≥80% BRANCH.

### Gate 6: Smoke Tests

```bash
lean-ctx ctx_shell npx newman run "postman/Goods Price Comparison Service.postman_collection.json"

```
Requires Spring Boot running locally on port 8080.

### Gate 7: SAST Security Scan

```bash
lean-ctx ctx_shell mvn verify -P security-check

```
OWASP Dependency-Check. CVSS >= 7 fails. Check `config/owasp/suppressions.xml`.

---

## Phase 4: Documentation

**Mandatory before creating PR.** Update CHANGELOG.md and README.md.

| Change Type | Files to Update |
|-------------|----------------|
| `feat` | `CHANGELOG.md` (Added), `README.md` if user-facing |
| `fix` | `CHANGELOG.md` (Fixed) |
| `refactor` | `CHANGELOG.md` (Changed) |
| `docs` | `CHANGELOG.md` (Changed), relevant `docs/` file |

### Humanizer Gate

**Mandatory for user-facing text outputs.** Run `/skill humanizer` over every user-facing document shipped in this release (README, docs, PR description, changelog, release notes) before creating the PR. Docs that still carry AI patterns (em dashes, rule-of-three, promotional tone) are not done. Internal state files (`session/state.md`, contract JSON, code comments) are exempt.

### Commit Template & Conventions

Use the **Conventional Commits** format for all commits. The project CHANGELOG is auto-generated from these via `changelogen`, so discipline here pays off in changelog quality.

**Commit format:**
```
<type>(<scope>): <brief description>

<optional body — explain what problem and why this approach>
```

**Types used in this project:**

| Type | When | CHANGELOG Section |
|------|------|-------------------|
| `feat` | New feature or endpoint | Added |
| `fix` | Bug fix | Fixed |
| `refactor` | Code change that adds no feature and fixes no bug | Changed |
| `test` | Adding or updating tests | (excluded from changelog) |
| `docs` | Documentation only | Changed |
| `style` | Formatting, spotless (no behavior change) | (excluded) |
| `chore` | Tooling, dependencies, config | (excluded — PR title documents grouped changes) |


| Scope | Example |
|-------|---------|
| `(test)` | `refactor(test): extract ServiceLayerNotFoundExceptionTest interface` |
| _(no scope)_ | `fix: replace System.out.println with Assumptions.assumeTrue in LlmServiceCacheTest` |
| (service name) | `feat(price): add batch price update endpoint` |

**Commit body conventions** (from real project commits):

```
1. Start with the problem: what was wrong / why change was needed
2. Describe the approach: how the fix/feature works
3. List concrete changes, especially notable ones (new files, deleted files, renames)
4. Quantify impact: "Net: +42/-158 lines across 12 files" or "1024 tests/0 failures"
5. Credit co-authors: "Co-authored-by: name <email>"
```


```
docs: update README, CHANGELOG, developer guide, and architecture docs (#148)

- README: add CI status badge, update test count to 1,024, refresh roadmap
  with test infrastructure and production readiness entries
- CHANGELOG: consolidate duplicate sections, update test counts
- Developer guide: add test slice patterns (WebMvcTest, DataJpaTest)
- Architecture docs: update ERD and migration listing
```

```
refactor(test): extract ServiceLayerNotFoundExceptionTest interface

New test interface with @Test default method for testing service-level
NotFoundException paths — 5 service tests (Price, BillSplit, Receipt,
ReceiptApproval, Product) now implement the interface, eliminating 5
duplicated test methods.
Net: -13 lines. 1024 tests/0 failures.
```

---

## Phase 4A: Semantic Versioning

The CHANGELOG declares adherence to [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html). Current version: `v1.0.0-SNAPSHOT` (pre-1.0).

### Version Bump Rules

| Bump | When | Project Examples |
|------|------|------------------|
| **MAJOR** | Breaking API contract change, new service domain, removed endpoint, changed request/response shape | New service (e.g. shopping optimizer), changed endpoint path, removed field from DTO |
| **MINOR** | New backward-compatible feature, new endpoint, new optional field | New CRUD endpoint, new query parameter, new event type |
| **PATCH** | Bug fix, refactor, performance improvement, documentation | Fix NPE, add missing index, consolidate duplicate code |

### Pre-1.0 Versioning (`0.x.y`)

Before `v1.0.0`, use `0.<MINOR>.<PATCH>`:

- **0.y.z** = treat `y` as MAJOR (breaking changes may happen at any minor bump)
- CHANGELOG [0.1.0] corresponds to project initialization
- Once API surface stabilizes (all 8 service domains have stable contracts), tag `v1.0.0`
- Consumers are warned that `0.x` means things can break — document migration notes per release

### How to Communicate Version Changes

1. **CHANGELOG.md** — Update the `[Unreleased]` section with the new version header once ready:
   ```markdown
   ## [1.0.0] - 2026-06-16
   ```
2. **Migration notes** — For MAJOR bumps, add a migration section at the top of the changelog:
   ```markdown
   ### Migration from 0.x to 1.0.0
   - `GET /v1/products` now returns paginated `ListResponseData` instead of raw array
   ```
3. **Tag the release**:
   ```bash
   ```
4. **GitHub Release** — Create with the changelog entry as description.

### When to Bump During Development

- **Before PR merge**: Bump version in `pom.xml` and CHANGELOG
- **Multiple PRs in flight**: Each PR bumps independently — resolve merge conflicts in `pom.xml` at merge time
- **Release cadence**: Batch PATCH-level fixes into a single weekly release; MINOR features per-feature as ready

---

## Phase 4B: Schema Versioning (Flyway)

The project uses **Flyway 12.8.1** with Maven plugin for database migration management. Configuration in `config/database.properties`:

```properties
spring.flyway.enabled=false
spring.flyway.locations=filesystem:db/migration/tables,\
                         filesystem:db/migration/alter,\
                         filesystem:db/migration/data
```

Flyway is **disabled at runtime** — run migrations explicitly via the Maven profile:
```bash
mvn flyway:migrate -Pflyway
```

It is also **disabled in tests** — Hibernate handles H2 schema via `ddl-auto=create-drop`.

### Migration Directory Structure

```
db/migration/
├── tables/          # Table creation (V1–V13)
│   ├── V1__create_stores_table.sql
│   ├── V2__create_products_table.sql
│   └── ...
├── alter/           # Schema alterations (V14+)
│   ├── V14__add_image_data_column_to_receipts.sql
│   ├── V15__add_missing_indexes.sql
│   └── ...
└── data/            # Seed/reference data
```

### Naming Convention

```
V<number>__<descriptive_snake_case_name>.sql
```

| Component | Rule | Examples |
|-----------|------|----------|
| Prefix | Always `V` (uppercase, versioned) | `V1__`, `V14__` |
| Number | Sequential integer, no gaps | Never reuse a number |
| Separator | Double underscore `__` | `V1__create_stores_table.sql` |
| Name | Snake case, describes the change | `add_image_data_column_to_receipts`, `add_missing_indexes` |
| Subdirectory | `tables/`, `alter/`, `data/` for organization | — |

**Migration naming patterns from actual project:**

| Pattern | Example |
|---------|---------|
| `V{next}__create_{table}_table.sql` | `V10__create_categories_table.sql` |
| `V{next}__add_{column}_column_to_{table}.sql` | `V14__add_image_data_column_to_receipts.sql` |
| `V{next}__add_missing_indexes.sql` | `V15__add_missing_indexes.sql` |
| `V{next}__add_missing_columns_to_{table}.sql` | `V6__add_missing_columns_to_products.sql` |
| `V{next}__normalize_{subject}.sql` | `V20__normalize_category_and_unit.sql` |
| `V{next}__drop_redundant_{object}_index.sql` | `V18__drop_redundant_price_summaries_index.sql` |

### What Goes Where

| Directory | Content | Examples |
|-----------|---------|----------|
| `tables/` | Initial `CREATE TABLE` statements | `CREATE TABLE stores (...)`, `CREATE TABLE prices (...)` |
| `alter/` | All schema changes after table creation | `ALTER TABLE ADD COLUMN`, `CREATE INDEX`, `ALTER TABLE ADD CONSTRAINT` |
| `data/` | Reference/seed data inserts | Lookups, enum reference values |

### Backward-Compatible Changes (Safe)

These can be applied without downtime and don't break existing code:

- `ADD COLUMN ... NULL` (nullable columns)
- `CREATE INDEX IF NOT EXISTS`
- `ADD CONSTRAINT` that doesn't change existing semantics
- Adding new tables

### Breaking Changes (Need Migration Plan)

These require coordinated application + database migration:

- `DROP COLUMN` — application reads fail if code still references it
- `ALTER COLUMN ... NOT NULL` — existing rows must be backfilled first
- `ALTER COLUMN ... TYPE` — may fail or truncate data
- `DROP TABLE` — application queries crash
- `RENAME COLUMN` or `RENAME TABLE` — breaks all references in code
- Long-running `ALTER TABLE` on large tables — acquires `ACCESS EXCLUSIVE` lock, blocks reads/writes

### Rollback Strategy

Flyway does **not support automatic rollback** of versioned migrations. Follow these practices:

1. **Each migration must be forward-only and additive when possible** — never `DROP` or destructive `ALTER` without a separate plan
2. **For breaking changes, deploy in phases:**
   - Phase 1: Add new columns/tables (backward-compatible)
   - Phase 2: Deploy application code that uses the new schema
   - Phase 3: Remove old columns (separate migration, separate deployment)
3. **Long-running migrations** (large table alters, data backfills): Execute manually, outside the Flyway run, to avoid locking. The project has precedent — deleted `V19` and `V21` from the migration chain and documented the manual process instead.
4. **To undo a migration in dev**: `mvn flyway:undo` (requires Flyway Teams/Enterprise) or manually write a compensating V{next} migration that reverses the change.
5. **Always test migrations against a copy of production data** before running in production.

### Migration Checklist

- [ ] Migration file follows `V{next}__descriptive_name.sql` naming
- [ ] File placed in correct subdirectory (`tables/`, `alter/`, or `data/`)
- [ ] SQL has a header comment explaining what and why
- [ ] `ADD COLUMN` defaults to nullable unless data is backfilled
- [ ] `CREATE INDEX` uses `IF NOT EXISTS`
- [ ] Migration tested against a copy of production data (data volume)
- [ ] No long-running operations on large tables without a manual execution plan
- [ ] Corresponding JPA entity changes in the same PR's code

---

## Phase 5: Pull Request

**PR Template:**

```markdown
## Summary

<1-3 bullet points>

## Related Issues

- Closes #<issue-number>

## Quality Checklist

- [ ] `mvn spotless:apply` — formatting clean

- [ ] `mvn test` — all tests pass

- [ ] `mvn verify` — SpotBugs + PMD CPD pass

- [ ] `mvn verify -P security-check` — OWASP passes

- [ ] `./scripts/check-conventions.sh` — conventions pass

- [ ] Smoke tests pass

- [ ] New code has unit tests (100% coverage for new code)

- [ ] CHANGELOG.md updated

- [ ] Humanizer pass on user-facing docs (`/skill humanizer`; no em dashes, rule-of-three, promotional tone)

- [ ] No unused code (YAGNI)

```
**Create PR:**

```bash
gh pr create --title "feat(scope): description" --body "<PR template>"

```
---

## Phase 6: Release Review

**Pre-merge:**

- All quality gates pass on CI

- At least one reviewer approved

- No TODOs/FIXMEs in new code

- Error messages use `ErrorMessageConstants`

- No secrets committed

**Post-merge:**

```bash


```
Create GitHub Release with changelog entry.

---

## Quick Reference

```text
1. PLAN    → planning/MASTER_PLAN.md

2. DEV     → port → service → mapper → adapter → constants → events → tests

3. QUALITY → spotless:apply → test → verify → check-conventions.sh → security-check

4. DOCS    → Update CHANGELOG.md + README.md + humanizer pass before PR

5. PR      → gh pr create --title "feat(scope): msg" --body "template"

6. REVIEW  → approve → merge → tag → release

```
## lean-ctx Conventions

When using this skill:

- Use `lean-ctx ctx_read` for reading files (cached, compressed, ~13 tok for unchanged files)

- Use `lean-ctx ctx_edit` for edits needing context persistence

- Use `lean-ctx ctx_shell` for all shell commands (NOT the `bash` tool — it's denied in opencode.json)

- After completing work, persist any new patterns/gotchas discovered: `lean-ctx ctx_knowledge remember category <cat> key <key> value <value>`

