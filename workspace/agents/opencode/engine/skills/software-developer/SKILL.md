---
name: software-developer
description: Full-stack software development following clean code, SOLID, and project-specific conventions
license: MIT
compatibility: opencode
tags:
  - clean-code
  - solid
  - refactoring
  - code-quality
  - design-patterns
file_patterns:
  - "**/*.java"
metadata:
  role: developer
  domain: engineering
triggers:
  - "clean code"
  - "SOLID"
  - "refactor"
  - "code quality"
  - "naming"
---

# Software Developer

## Mindset

- Write code for humans first, machines second

- Favor clarity over cleverness

- Every abstraction has a cost — justify it

- Prefer composition over inheritance

## Before Writing Code

1. Understand existing patterns (read 2-3 similar files)

2. Check AGENTS.md and available skills

3. Identify edge cases and failure modes upfront

4. Consider testability

## Code Quality

- One responsibility per function/class

- Names reveal intent: `calculateTotal()` not `processData()`

- Minimize mutable state, prefer immutability

- Fail fast: validate at boundaries

- Handle errors at the appropriate layer

## Testing

- Write tests alongside code

- One logical assertion per test

- Test behavior, not implementation

- Edge cases: empty, null, boundary values

## Project-Specific Patterns

### Utilities (from `common/util/`)

- Use `ObjectUtils.defaultIfNull(obj, fallback)` for null-safe defaults

- Use `ObjectUtils.getOrNull(obj, X::getY)` for chained null-safe access

- Use `ValidationUtils.requireNonNull(x, "name")` to validate at boundaries

- Use `NumberUtils.toDouble(obj)` for safe numeric conversion

- Use `PaginationUtils` and `SortingUtils` for paginated queries

### Constants (from `common/constant/`)

- `ErrorCodes` — error identifiers for all exceptions

- `AppConstants` — string, numeric, and date constants

- `ErrorMessageConstants` — message templates (never hardcode error messages)

### Response Helpers

- Return paginated results: `PageResponse.of(content, page, size, totalElements)`

- Controller responses: `ControllerResponse.ok(body)`, `.created(body)`, `.noContent()`

### Events

- Domain services publish via `*EventOutPort` — never fire events outside a transaction

- Handlers are `@Async @TransactionalEventListener(phase = TransactionPhase.AFTER_COMMIT)`

## C4 Model for Architecture Documentation

Use the C4 model (Context, Container, Component, Code) to document architecture at four levels of
abstraction. This is the **primary documentation approach** for all significant architecture decisions.

### The Four C4 Levels

| Level | Name | Audience | What It Shows | Format |
|-------|------|----------|---------------|--------|
| C1 | **Context** | Everyone (devs, PM, stakeholders) | System boundary, users, external integrations | `docs/diagrams/context.puml` |
| C2 | **Container** | Developers, DevOps | High-level tech decisions: web app, API, DB, message bus | `docs/diagrams/container.puml` |
| C3 | **Component** | Developers on this service | Internal structure: ports, domain services, adapters | `docs/diagrams/component-{domain}.puml` |
| C4 | **Code** | Developers implementing the feature | Key classes, interfaces, relationships | Inline comments + ArchUnit tests |

### When to Use Each Level

- **C1 Context**: At project inception, when adding a new integration (external API, downstream service),
  or when onboarding a new team member. Updated when system boundaries change.
- **C2 Container**: During architecture review, when adding a new service domain, changing the event bus,
  or modifying the database topology. Updated per major release.
- **C3 Component**: Before implementing a new feature in an existing domain (e.g., adding receipt OCR
  to the receipt service). Updated when port interfaces or domain services change.
- **C4 Code**: Continuously — ArchUnit tests ARE live C4 diagrams. Write ArchUnit rules to enforce
  package structure, layer dependencies, and naming conventions.

### Hexagonal → C4 Mapping

```
C1 — Context:    User → Goods Price Comparison System → External APIs (OCR, LLM, pricing feeds)
C2 — Container:  Web App → REST API → Database → Event Bus → LLM Service
C3 — Component:  Each of 8 domains (receipt, price, product, store, llm, shopping, alert, system):

                 ┌──────────────────────────────────────┐
                 │  application/ (pure Java)             │
                 │  ├── port/in/     ← WebAdapter        │
                 │  ├── port/out/    → RepositoryAdapter  │
                 │  │                → EventAdapter       │
                 │  ├── domain/service/                   │
                 │  └── domain/model/                     │
                 ├──────────────────────────────────────┤
                 │  infrastructure/ (adapters)            │
                 │  ├── adapter/web/   (controller)       │
                 │  ├── adapter/persistence/ (JPA)        │
                 │  └── adapter/event/  (pub/sub)         │
                 └──────────────────────────────────────┘

C4 — Code:       ArchUnit rules at test/java/**/architecture/*Test.java
```

### Docs-as-Code Approach for Diagrams

- Store diagrams as PlantUML (`.puml`) in `docs/diagrams/` — version-controlled alongside code
- Generate PNG/SVG on commit via CI pipeline or pre-commit hook
- Reference diagram files from architecture docs using relative paths
- ArchUnit tests serve as **executable C4 documentation**: changing a package structure
  without updating tests = failed build

### Keeping Diagrams in Sync

1. **PR gate**: If a PR changes port interfaces or adds a new adapter, reviewer checks that
   the corresponding C3 component diagram is updated
2. **Automated check**: `mvn verify` includes ArchUnit — layer violations always fail the build
3. **Scheduled review**: Re-generate all diagrams quarterly to catch drift

---

## Docs-as-Code

All project documentation lives in the repository alongside source code. No separate wiki,
no Google Docs for architecture decisions.

### Documentation Repository Layout

```
docs/
├── adr/                  ← Architecture Decision Records (0001-*.md)
├── diagrams/             ← PlantUML source files
├── api/                  ← OpenAPI/Swagger specs (auto-generated)
├── planning/             ← Planning docs, Gherkin scenarios
└── reports/              ← Analysis reports
README.md                 ← Project overview, quick start
ARCHITECTURE_HYBRID.md    ← System architecture deep-dive
CHANGELOG.md              ← Release notes per version
```

### Architecture Decision Records (ADRs)

Use ADRs for any **significant, irreversible, or costly** decision:

| When to Write an ADR | Example |
|----------------------|---------|
| Choosing a technology or framework | "Use Spring Boot 3.4 with virtual threads" |
| Changing system topology | "Migrate from synchronous REST to event-driven between services" |
| Adding a new service domain | "Introduce alert domain for threshold monitoring" |
| Reversing a previous decision | "ADR 0012: Supersede ADR 0007 — replace manual OCR with LLM-based extraction" |
| Introducing a new pattern | "Use Strangler Fig for incremental LLM migration" |

ADR template (at `docs/adr/0000-template.md`):
```markdown
# ADR-{NNNN}: {Title}

**Status**: [Proposed | Accepted | Deprecated | Superseded]
**Date**: {YYYY-MM-DD}
**Deciders**: {list of approvers}

## Context
{What problem are we solving? What constraints apply?}

## Decision
{What did we decide? Why this option over alternatives?}

## Consequences
{Trade-offs, risks, follow-up work required}
```

Keep ADRs under `docs/adr/` with sequential numbering (`0001-use-spring-boot.md`).

### Auto-Generated Documentation

| Source | Generator | Output | When to Regenerate |
|--------|-----------|--------|--------------------|
| OpenAPI annotations on controllers | `springdoc-openapi` | `docs/api/openapi.json` | Before each release |
| ArchUnit rules | JUnit test runner | Console output / CI logs | Every `mvn verify` |
| JaCoCo coverage | Maven plugin | `target/site/jacoco/` | Every `mvn verify` |
| SpotBugs/PMD/CPD reports | Maven plugins | `target/` reports + CI gate | Every `mvn verify` |

### When to Update Which Document

| Document | Update Trigger | Owner |
|----------|---------------|-------|
| `README.md` | New dependency, changed build steps, new service domain | Developer |
| `ARCHITECTURE_HYBRID.md` | Changed system topology, added event flow, new integration | Software Architect |
| `CHANGELOG.md` | Every release (`## [X.Y.Z] - YYYY-MM-DD` with links to PRs) | Developer |
| `docs/adr/*.md` | Significant decision (see table above) | Orchestrator / Architect |
| `docs/diagrams/*.puml` | Port/interface changes, new adapters | Developer |
| `docs/planning/*.md` | Before execution phase begins | System Analyst |

**Rule of thumb**: If a code change takes >1 hour to implement, it deserves a documentation update.
If it takes >1 day, it deserves an ADR.

---

## Strangler Fig Pattern

The Strangler Fig pattern incrementally replaces legacy functionality with new implementation
while the system remains operational. Apply this when migrating from one implementation to
another (e.g., replacing a synchronous call with an event-driven flow).

### When to Use

- Replacing an existing feature piece by piece (not a big-bang rewrite)
- Migrating between external providers (e.g., switching OCR engines, LLM providers)
- Refactoring from monolithic to event-driven within a domain
- Introducing a new pattern alongside existing code before fully deprecating the old path

**Do NOT use** for greenfield features, one-shot replacements (small scope), or when
the old system can be taken offline during a maintenance window.

### How It Applies to Our Event-Driven Architecture

Our event-driven architecture is naturally suited to strangulation because events
act as **decoupling points**:

```text
Old Path:     Controller → ServiceA → ServiceB (synchronous call)
                                                  ↓
Transition:   Controller → ServiceA ──publish──→ EventHandler → ServiceB
                                                  ↓
New Path:     Controller → ServiceA ──publish──→ NewEventHandler → NewServiceB
```

Each domain can be strangulated independently:

| Domain | Strangulation Candidate | Strategy |
|--------|------------------------|----------|
| `receipt` | Replace manual OCR with LLM-based extraction | Route-based: new endpoint, old deprecated |
| `price` | Migrate from REST price feed to event-driven updates | Domain-based: new flow emits events, old path still works |
| `llm` | Switch LLM provider (OpenAI ↔ Anthropic) | Implementation swap behind `LlmInPort` interface |
| `shopping` | Replace in-memory list with persisted list | Data + code migration in lockstep |

### Route-Based vs Domain-Based Strangulation

**Route-based**: Add new endpoint, deprecate old endpoint, redirect traffic gradually.

```
GET /api/v1/products        → old implementation (deprecated)
GET /api/v2/products        → new implementation (preferred)

Pro: Easy to A/B test, per-route metrics
Con: URL versioning pollution, controller grows
```

**Domain-based**: Strangulate at the service boundary — old and new domain services coexist,
routed by configuration flags or feature toggles.

```
OldReceiptService  ← used by ReceiptController  when flag=OLD
NewReceiptService  ← used by ReceiptController  when flag=NEW

Pro: Clean domain isolation, no URL changes
Con: Two implementations to maintain during transition
```

### Data Migration Alongside Code Migration

When strangulation involves data changes, synchronize data and code migration in three phases:

| Phase | Code | Data | Success Signal |
|-------|------|------|----------------|
| **1. Coexist** | Both old and new paths run, writing to old + new tables/columns | Dual-write with backfill job | No data loss, consistency verified |
| **2. Switch** | Feature toggle flips to new path; old path reads only | Reads from new location; old data frozen | All queries served from new path |
| **3. Cleanup** | Remove old path, delete deprecated endpoints | Drop old tables, columns, migration scripts | Old code deleted, no regressions |

**For our project**: Most entity changes follow Flyway migrations with `V{version}__{description}.sql`.
During strangulation phases 1-2, write to both old and new columns; in phase 3, drop old columns.

**Critical rule**: Never migrate code and data simultaneously in a single deployment.
Always phase them — code first (dual-write), then data migration, then code cleanup.

---

## Technical Debt Quadrants

Use Martin Fowler's quadrant model to classify and prioritize technical debt. Not all debt
is bad — some is strategic. The key is knowing which quadrant it falls into.

### The Four Quadrants

```
                  Deliberate                    Inadvertent
                  (you chose it)                (you didn't know)
┌──────────────────────────────────────────────────────────┐
│                    │                                      │
│   Reckless   │  Q1: "We'll fix it later"      Q2: "I didn't know better"      │
│   (bad)      │  Strategic shortcut taken       Accidental complexity from     │
│                    │  knowingly                    learning/unfamiliarity       │
│                    │  e.g., copy-paste for        e.g., missing null checks,   │
│                    │  deadline, skipping tests    wrong abstraction layer      │
│                    │                                      │
├────────────────┼──────────────────────────────────────┤
│                    │                                      │
│   Prudent     │  Q3: "We'll pay it down"        Q4: "We're learning"          │
│   (managed)   │  Intentional debt with a        Discovered while coding,      │
│                    │  repayment plan                 now you know better        │
│                    │  e.g., throwing an         e.g., realizing a port is     │
│                    │  exception in a shared      too coarse, need to split    │
│                    │  utility, add a TODO        it into two interfaces       │
│                    │  with JIRA ticket #             │                                      │
└──────────────────┴──────────────────────────────────────┘
```

### How to Categorize Debt in This Project

| Symptom | Typical Quadrant | Action |
|---------|-----------------|--------|
| SpotBugs HIGH priority finding | Q1 (reckless/deliberate — someone knew) | Fix immediately — build gate fails |
| SpotBugs NORMAL/LOW finding | Q2 (inadvertent) or Q4 (learning) | Triage: fix if in changed code, log issue otherwise |
| Missing ArchUnit test for new package | Q2 (didn't know about the rule) | Add the test, update AGENTS.md reference |
| Duplicate code (PMD CPD violation) | Q1 or Q4 — depends on intent | Extract shared utility in `common/util/` |
| Null not handled in domain service | Q4 (discovered during review) | Add `ValidationUtils.requireNonNull()` guard |
| `@ManyToOne` annotation found (violates rules) | Q2 (didn't know ArchUnit rule #4) | Remove annotation, use primitive FK. Add ArchUnit test |
| Hardcoded error message instead of `ErrorMessageConstants` | Q2 or Q1 | Extract to constants. Add to ErrorMessageConstants |
| Deprecated endpoint still in use | Q3 (strategic, with migration plan) | Add deprecation notice, set expiry date |
| Migration from REST to events half-done | Q3 (planned strangulation) | Track in ADR, complete strangulation phases |

### When to Pay Down vs Live With Debt

**Pay down immediately** (must-fix):
- Build gate failures (SpotBugs HIGH, PMD CPD, ArchUnit violations)
- Security vulnerabilities
- Production bugs or data integrity issues
- Anything blocking a feature in the current sprint

**Pay down this sprint** (should-fix):
- SpotBugs NORMAL findings in changed files
- Q4 debt discovered during current work (you know better now)
- Duplication that would multiply if left unchecked
- Missing tests for core domain logic

**Live with it** (tracked, not fixed):
- Q3 strategic debt with a documented repayment plan and JIRA ticket
- Deprecated code scheduled for removal in a future release
- Cosmetic issues in code not being modified (follow the boy-scout rule sparingly)
- Q1 debt that the team consciously accepted (e.g., skipping integration tests for a prototype)

### Integrating with Our Quality Gates

Our build pipeline (`mvn verify`) already captures most debt signals. Map findings to quadrants:

| Gate | Finding | Debt Quadrant | Fail Build? |
|------|---------|---------------|:-----------:|
| Spotless | Formatting violation | Q2 | Yes |
| SpotBugs | HIGH priority | Q1 | Yes |
| SpotBugs | NORMAL priority | Q2/Q4 | No |
| SpotBugs | LOW priority | Q4 | No |
| PMD CPD | Duplicate code block | Q1/Q4 | Yes (>100 tokens) |
| ArchUnit | Layer violation | Q2 | Yes |
| JaCoCo | <90% INSTRUCTION coverage | Q2/Q4 | Yes |
| JaCoCo | <80% BRANCH coverage | Q2/Q4 | Yes |

**Local workflow**:
```bash
# Before committing, run
mvn spotless:apply           # Fix formatting (prevents Q2 debt)
mvn test                     # Check tests + ArchUnit + JaCoCo
mvn spotbugs:check           # Check SpotBugs violations
mvn pmd:check pmd:cpd        # Check PMD + CPD violations

# If SpotBugs HIGH is found, fix it — don't commit debt you'll regret.
```

**Debt tracking** in code:
```java
// Q3 strategic debt — tracked in ADR-0015
// TODO: Remove this class after LLM migration phase 3 (target: Q3 2026)
@Deprecated
public class LegacyReceiptProcessor { ... }
```

Use `lean-ctx ctx_knowledge remember` to persist frequently encountered debt patterns:

```bash
# After finding a recurring debt pattern:
lean-ctx ctx_knowledge remember category gotchas key "archunit/many-to-one-reappears" value "Devs keep adding @ManyToOne. Reminder: rule #4 — FKs are primitives, never JPA relationships." severity warning
```

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

