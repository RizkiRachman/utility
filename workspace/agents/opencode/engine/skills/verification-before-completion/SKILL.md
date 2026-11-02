---
name: verification-before-completion
description: Verifies that work meets all success criteria before marking a task complete. Prevents premature sign-off and rework.
---

# Verification Before Completion

Production-ready verification for the Goods Price Comparison Service. Every item defines **what pass looks like**, what **false positives** to watch for, and whether to **automate or manually check**. Run in the prescribed order: fastest-failing checks first.

---

## Optimal Verification Order

Run in this sequence. Each step gates the next — fail fast, fix fast.

| # | Check | Est. Time | Gate | Why This Order |
|---|-------|-----------|------|-----------------|
| 1 | Scope discipline | 10s | Fail → STOP | Catches unauthorized changes immediately |
| 2 | Format (Spotless) | 5s | Fail → FIX | Fastest build gate; unformatted code blocks everything |
| 3 | Compile | 15s | Fail → FIX | Syntax/import errors; must pass before tests |
| 4 | Unit tests (affected module) | 30s | Fail → FIX | Fast module-level feedback |
| 5 | Full `mvn test` | 2m | Fail → FIX | All tests + ArchUnit rules |
| 6 | Full `mvn verify` | 3m | FAIL → BLOCK | SpotBugs + PMD CPD + all above |
| 7 | Impact analysis | 10s | Fail → FLAG | Unexpected blast radius |
| 8 | Edge cases review | 2m | Manual | Human judgment required |
| 9 | Knowledge persistence | 30s | Fail → FLAG | Durable capture of gotchas/patterns |
| 10 | STATE.md + session save | 20s | Fail → FLAG | Cross-session continuity |

**Rule**: If any step fails, fix before proceeding. Do not skip steps 5-6 to "save time" — that is a false economy.

---

## 1. Scope Discipline

**What pass looks like**: Only files listed in the task's `scope.included` were modified.

```
```

**Accept**: Task files + test files for same scope.

**Flag**: File outside `scope.included` touched — document why.

**Block**: `ci/`, `.github/`, `pom.xml` (unless in scope), port interfaces from other domains, shared infrastructure — modified without authorization.

**False positives**: `pom.xml` changes from Maven plugin auto-entries (rare); Spotless formatting-only diffs.

---

## 2. Format (Spotless)


**False positives**: Ran on wrong module; XML exclusions skipped some files; tabs/spaces not flagged by Spotless.

**Threshold**: PASS = no violations. FLAG = formatting-only changes in untouched files (squash separately). FIX immediately — never commit unformatted code.

---

## 3. Compile

**Pass**: `mvn compile -q && mvn test-compile` → silent success, exit 0.

**Block** on any compilation failure. No exceptions.

**False positive**: `mvn compile` OK but `mvn test-compile` fails (missing test deps). Always run both.

---

## 4. Tests (All Passing)

**What pass looks like**:
```
mvn test    # → Tests run: 42, Failures: 0, Errors: 0, Skipped: 0
```

**FLAG**: Tests were skipped (`Skipped: N` where N > 0) — did you intentionally skip or did a `@Disabled` creep in?
**FLAG**: Flaky tests — a test that fails intermittently. Run 3x. If it fails 1/3, mark as flaky and report it.
**BLOCK**: Any test failure. No exceptions for "unrelated" failing tests — fix or document before marking complete.

**Common false positives**:
- "Tests pass" but you ran the wrong module: `mvn test -pl unrelated-module`
- "Tests pass" but you forgot `@ActiveProfiles("test")` and tests used production DB
- H2 tests pass but PostgreSQL-specific behavior differs — note this as a risk
- Mock-heavy tests pass but integration flow is untested — flag coverage gap

**Threshold**:

| Condition | Verdict |
|-----------|---------|
| All pass, coverage ≥ 80% on new code | PASS |
| All pass, coverage 60-79% on new code | FLAG (acceptable if critical path covered) |
| All pass, coverage < 60% on new code | BLOCK (deficient) |
| Any failure | BLOCK |
| Any skipped test without `@Disabled(reason = "...")` | FLAG |
| Flaky test (passes 2/3 runs) | FLAG with report |

---

## 5. Quality Gates (Full `mvn verify`)

**What pass looks like**:
```
mvn verify    # → BUILD SUCCESS
              #   Spotless:check passed
              #   Tests passed (ArchUnit: 7 rules matching)
              #   SpotBugs: No bugs found
              #   PMD CPD: No duplications found
```

**Check each gate explicitly**:

| Gate | What It Checks | Pass Signal | Common False Positive |
|------|---------------|-------------|----------------------|
| **ArchUnit** | Hexagonal layering, port usage, no JPA in domain | 7 rules pass | A rule passes because no code exercises it — add a test that exercises the pattern |
| **SpotBugs** | Null safety, resource leaks, concurrency bugs | Zero bugs, any severity | Low-priority bugs (e.g., "non-static field in enum") that may be intentional — flag for review |
| **PMD CPD** | Copy-paste duplication | Duplication < 50 tokens threshold | Legitimate similarity (e.g., generated code, builders) — exclude known patterns |
| **Spotless** | Google Java Style | All files compliant | Auto-fix on save may introduce whitespace changes not caught until CI |

**Threshold**:

| Condition | Verdict |
|-----------|---------|
| All 4 gates pass | PASS |
| Only SpotBugs "Info" level warnings | FLAG (acceptable, document) |
| SpotBugs "Warning" or "Error" level | BLOCK |
| PMD CPD > 50 tokens (non-generated) | BLOCK |
| Any ArchUnit violation | BLOCK |
| Spotless:check fails | FIX (run `spotless:apply`) |

---

## 6. Impact Analysis (Blast Radius)

**What pass looks like**:
```
ctx_impact({target: "changedSymbol", direction: "upstream"})
# → Risk: LOW, d=1 callers: 2 (expected), affected processes: 1 (the one you changed)
```

**Interpretation**:

| Risk Level | Verdict |
|-----------|---------|
| LOW (0-5 total affected symbols) | PASS — proceed |
| MEDIUM (6-20 symbols or 2+ processes) | FLAG — review affected processes, verify tests cover them |
| HIGH (21-50 symbols or cross-module) | FLAG + require human review before merge |
| CRITICAL (50+ symbols, multiple modules, shared infra) | BLOCK — escalate to orchestrator |

**False positives**:
- Impact shows 100 callers but 95 are in generated code (mappers/lombok) — check `kind` filter
- Cross-module impact from renaming a common utility that only one service actually uses
- Impact shows changes to test files that don't affect production — these are acceptable but note them

**Must also run**:
```
ctx_delta()    # Verify expected scope only
```

---

## 7. Edge Cases & Error Paths (Manual Review)

**What pass looks like**: Every new or modified method handles null inputs, empty collections, boundary values, and exception paths.

**Checklist**:
- Null inputs — does the method NPE on null? If public, it must handle or document.
- Empty collections — `List.of()` vs `null` vs empty list. Stream operations on empty lists are safe, but `get(0)` is not.
- Boundary values — ID=0, Long.MAX_VALUE, pagination page=0 vs page=1.
- Exception paths — does `NotFoundException` from the domain become 404 (not 500) in `GlobalExceptionHandler`?
- Idempotency — if the operation runs twice, is the second run safe (no duplicate-key errors, no side effects)?

**Threshold**:

| Condition | Verdict |
|-----------|---------|
| All new methods have null/empty handling | PASS |
| Missing null check on public API or port | BLOCK |
| Controller returns 500 for expected domain exception | BLOCK |
| No edge case tests for CRUD operations | FLAG |

**False positive**: Lombok `@Builder` with unset fields — those fields are null by default, not handled. JPA `@Column(nullable=false)` catches nulls at DB level, but domain layer should catch them first.

---

## 8. Knowledge Persistence

**What pass looks like**: Gotchas, patterns, and decisions discovered during the task are saved.

```bash
lean-ctx ctx_knowledge remember key "gotcha/your-gotcha" value "..." category "gotchas"
lean-ctx ctx_knowledge remember key "pattern/your-pattern" value "..." category "conventions"
```

| Artifact | Required? | Threshold |
|----------|-----------|-----------|
| Gotcha discovered | If one arose | FLAG if not persisted — will cause bugs next session |
| New convension/pattern | If one emerged | FLAG if not persisted — will be forgotten |
| Architectural decision | If one was made | FLAG if not persisted — context lost |
| None (routine work) | Skip | PASS |

**False positive**: "I'll remember it" — you won't. Always persist.

---

## 9. STATE.md + Session Save

**STATE.md**: Append completed work, update Current Focus, update Known Blockers.
- PASS = accurately reflects reality
- BLOCK = contradicts what you just did

**Session save**: `lean-ctx ctx_session save` — mandatory after every task.
- PASS = saved. No exceptions.
- OpenCode restarts lose context. This is your safety net.

---

## Decision Matrix: When to Accept vs Block

| Scenario | Verdict | Action |
|----------|---------|--------|
| All checks pass | PASS | Mark complete, update contract outputs |
| Auto-checks pass, 1 manual FLAG | PASS | Note in output, proceed |
| Edge case missing on non-critical path | PASS WITH NOTE | Fix, note in output, proceed |
| SpotBugs "Info" warnings only | PASS WITH NOTE | Document in knowledge |
| Tests pass, coverage < 60% on new code | BLOCK | Add coverage before proceeding |
| Any ArchUnit violation | BLOCK | Fix layering violation |
| `mvn verify` fails any gate | BLOCK | Fix failure |
| Impact shows HIGH/CRITICAL risk | BLOCK | Escalate to orchestrator |
| Impact shows MEDIUM risk | FLAG | Review affected processes |
| STATE.md not updated | FLAG | Update before merging |
| Gotcha discovered, not persisted | FLAG | Persist before session end |
| Scope violation on infra/cross-service file | BLOCK | Revert or escalate |
| All tests pass, none are new | FLAG (feature) / PASS (refactor) | Add test per new behavior |

---

## Summary: The Minimum Viable Gate

If you are under severe time pressure and MUST trim, this is the non-negotiable minimum:

1. **`mvn verify`** — must pass all 4 gates
2. **`ctx_delta()`** — verify scope
3. **`STATE.md` update** — cross-session continuity
4. **`ctx_session save`** — resumability

Skip nothing else. If any of these 4 fail, the task is not complete.
