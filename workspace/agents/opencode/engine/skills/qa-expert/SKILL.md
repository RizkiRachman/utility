---
name: qa-expert
description: Quality assurance — test strategy, coverage analysis, bug detection, and regression prevention
license: MIT
compatibility: opencode
tags:
  - testing
  - quality-assurance
  - coverage
  - regression
  - bug-detection
file_patterns:
  - "**/*Test*.java"
  - "**/test/**/*.java"
metadata:
  role: qa
  domain: quality
triggers:
  - "test strategy"
  - "coverage"
  - "bug detection"
  - "regression"
  - "test quality"
---

# QA Expert

## Project Test Structure

**Unit**: `@ExtendWith(MockitoExtension.class)`, domain services only. Files: `ProductServiceTest`, `PriceServiceTest`, `ReceiptServiceTest`.

**Controller**: `GlobalExceptionHandlerTest` — direct handler invocation, no Spring context.

**Architecture**: `HexagonalArchitectureTest` — 7 ArchUnit rules (dependency, JPA, port, naming).

## Testing NotFoundException

Domain services use static factories (`NotFoundException.product(id)`, `NotFoundException.price(id)`):

```java
// Domain service throws:

throw NotFoundException.product(999L);

// Test asserts:

assertThrows(NotFoundException.class, () -> productService.findById(999L));

// Controller handler test:

var response = handler.handleNotFound(NotFoundException.product(999L));

assertEquals(HttpStatus.NOT_FOUND, response.getStatusCode());

assertEquals(ErrorCodes.PRODUCT_NOT_FOUND, response.getBody().get("error"));

```
## Key Checks

- Every find/update/delete path throws `NotFoundException` when entity not found

- Test `verify(repo, never())` after exception — no side effects

- Repository returning `null` → domain throws, never passes null to caller

- 7 ArchUnit rules in `HexagonalArchitectureTest` must all pass

- Prefer `PageResponse.of(List.of(domain), 0, 20, 1)` over complex mock chains

- Over-mocked tests are a red flag — test real behavior, not mocks

## Coverage Focus

- Error paths (NotFoundException, IllegalArgumentException), edge inputs (null, empty), empty results

- Risk areas: rate limiting, duplicate detection, LLM provider fallback (`LlmProviderType.fromValue()`)

## Regression Prevention

- Every bug fix needs a test that fails without the fix

- Check sibling services for the same bug pattern

- Re-run ArchUnit tests after structural changes

## Property-Based Testing (jqwik)

Property-based testing (PBT) complements example-based tests by verifying **invariants**
over many generated inputs. Use **jqwik** (JUnit 5 integration) for this in the
goods-price-comparison-service project.

### When to Use PBT

| Scenario | Example Invariant | Why PBT Wins |
|----------|-------------------|--------------|
| **Serialization/Deserialization idempotency** | `domain → toEntity() → Entity → toDomain() → domain` preserves all fields | Catches mapping drift when entities gain/lose columns |
| **Sort order stability** | `List.sort(comparator)` then `sort(comparator)` again yields same order | Detects non-transitive or inconsistent comparators |
| **Pagination correctness** | `pageSize * page <= totalElements` for valid pages; `page * size >= totalElements` → empty content | Catches off-by-one in `PageResponse.of()` logic |
| **Rounding / precision** | `BigDecimal` arithmetic never loses scale; `price * quantity = total` | Catches truncation vs. rounding errors |
| **Enum round-trip** | `LlmProviderType.fromValue(x).getValue()` equals `x` for every enum constant | Protects against value drift |
| **Validation logic** | Every generated `String` of length > 255 fails `@Size(max=255)` constraint | Catches boundary logic gaps |

### Example: PageResponse Invariant Test

```java
import net.jqwik.api.*;
import com.example.goodsprice.common.dto.PageResponse;

class PageResponseProperties {

  @Property
  void pageResponseInvariantsHold(
      @ForAll @IntRange(min = 0, max = 1000) int page,
      @ForAll @IntRange(min = 1, max = 100) int size,
      @ForAll @IntRange(min = 0, max = 10_000) long totalElements,
      @ForAll List<@StringLength(max = 10) String> items
  ) {
    var response = PageResponse.of(items, page, size, totalElements);
    
    // Total pages must be consistent
    var expectedPages = (int) Math.ceil((double) totalElements / size);
    assertThat(response.totalPages()).isEqualTo(expectedPages);
    
    // first/last flags
    assertThat(response.first()).isEqualTo(page == 0);
    assertThat(response.last()).isEqualTo(page >= expectedPages - 1);
    
    // Content is never null
    assertThat(response.content()).isNotNull();
  }
}
```

### Example: DTO Mapping Idempotency

```java
@Property
void priceMappingRoundTrip(
    @ForAll @IntRange(min = 1, max = 10_000) Long id,
    @ForAll @BigRange(min = "0.01", max = "9999.99") BigDecimal amount,
    @ForAll @IntRange(min = 1, max = 500) Long storeId
) {
  var domain = PriceDomain.builder().id(id).price(amount).storeId(storeId).build();
  var entity = priceMapper.toEntity(domain);
  var restored = priceMapper.toDomain(entity);
  
  assertThat(restored.getId()).isEqualTo(domain.getId());
  assertThat(restored.getPrice()).isEqualByComparingTo(domain.getPrice());
  assertThat(restored.getStoreId()).isEqualTo(domain.getStoreId());
}
```

### PBT Integration Rules

- Place jqwik tests in the existing test directory (`src/test/java/`), in a `*Properties.java` file alongside `*Test.java` classes
- Add jqwik dependency to `pom.xml` (check current versions; latest is jqwik 1.9.x compatible with JUnit 5)
- Do NOT use PBT for trivial getter/setter tests — reserve for invariants that would need 20+ example-based tests to cover
- Run jqwik tests with `mvn test` — they participate in the same Surefire execution
- Combine with Mockito via `@Provide` methods: generate domain objects, mock repository returns, verify service invariants

## Mutation Testing Thresholds

Mutation testing evaluates test quality by introducing small faults (mutations)
into production code and checking whether existing tests **kill** (detect) them.
Surviving mutations reveal untested paths, weak assertions, or missing edge cases.

### Concept Overview

| Term | Meaning |
|------|---------|
| **Mutation** | Single syntactic change: `>` → `>=`, `true` → `false`, `+` → `-`, `null` → non-null |
| **Killed** | At least one test fails on the mutated code (good — test caught it) |
| **Survived** | All tests pass on the mutated code (bad — gap in coverage) |
| **Mutation Score** | `Killed / (Killed + Survived)` — the % of mutations your tests detect |

### Why Thresholds Matter

This project enforces **≥80% INSTRUCTION** and **≥80% BRANCH** coverage via JaCoCo
(configured in `pom.xml` as `<coverage.minimum>0.80</coverage.minimum>` and
`<coverage.branch.minimum>0.80</coverage.branch.minimum>`). However, coverage
percentages alone are misleading — 100% line coverage with no assertions kills zero
mutations. Mutation score fills this gap:

| Metric | What It Measures | Blind Spot |
|--------|------------------|------------|
| JaCoCo INSTRUCTION | Which lines executed | Says nothing about assertions |
| JaCoCo BRANCH | Which branch directions taken (`if`/`else`) | Doesn't check branch *results* |
| Mutation Score | Whether tests detect behavior changes | Requires more runtime |

### Relating Thresholds to the Project

For this project's Java 21 + Spring Boot hexagonal architecture:

1. **Domain services** (e.g., `PriceService.searchByProduct()`) should achieve
   **≥85% mutation score** — these contain business logic with branching on
   `Objects.isNull()`, date ranges, and price calculations. A surviving mutation
   like `Objects.nonNull(startDate)` → `always true` means you missed the
   null-startDate path.

2. **Repository adapters** (e.g., `PriceRepositoryAdapter`) — aim for **≥70%**.
   JPA repository methods delegate to Spring Data, so many mutations in wiring
   (repository field null, wrong method called) are caught by verifying
   interactions with `verify(repo).findByProductId(...)`.

3. **Web adapters / controllers** — aim for **≥75%**. Focus on status code mapping,
   error response bodies, and pagination. Test patterns:
   ```java
   // Weak — doesn't verify response body structure
   assertThat(response.getStatusCode()).isEqualTo(HttpStatus.OK);
   
   // Stronger — verifies content
   var body = response.getBody();
   assertThat(body).isNotNull();
   assertThat(body.get("data")).isNotNull();
   ```

4. **GlobalExceptionHandler** — **≥90% mutation score**. Every known exception type
   (`NotFoundException`, `IllegalArgumentException`, unexpected) needs a test that
   verifies the status code AND the response body structure.

### Common Mutation Types & What They Expose

| Mutation | What Survives If… | Fix |
|----------|-------------------|-----|
| `> → >=` | You only tested the happy path boundary | Test _exactly_ the boundary value + 1 |
| `false → true` | You never tested the `condition == false` branch | Add a test for the negative case |
| `return null → non-null` | Caller doesn't null-check | Assert `isNotNull()` after the call |
| `remove method call` | Side-effect method isn't verified | Add `verify(mock).method()` |
| `"errorCode" → empty` | Test checks status only, not error code | Assert `response.getBody().get("error")` |

### Running Mutation Tests

This project does not yet have PIT or similar mutation testing configured in
`pom.xml`. To introduce it:

```xml
<plugin>
  <groupId>org.pitest</groupId>
  <artifactId>pitest-maven</artifactId>
  <version>1.17.1</version>
  <configuration>
    <targetClasses>
      <param>com.example.goodsprice.*</param>
    </targetClasses>
    <targetTests>
      <param>com.example.goodsprice.*</param>
    </targetTests>
    <excludedClasses>
      <param>com.example.goodsprice.common.dto.*</param>
      <param>com.example.goodsprice.common.exception.*</param>
    </excludedClasses>
    <mutationThreshold>75</mutationThreshold>
  </configuration>
</plugin>
```

Run with: `mvn org.pitest:pitest-maven:mutationCoverage`

Use mutation reports (`target/pit-reports/`) alongside JaCoCo reports to identify
weak spots. A module that passes JaCoCo (80%) but scores <60% on mutation is
**assertion-poor** — add behavior-verifying tests.

## Collaboration & PR Review Etiquette

Code review in the goods-price-comparison-service project follows a constructive,
engineering-driven model. Reviews are not gatekeeping — they are knowledge transfer
with quality assurance built in.

### What to Look For (Checklist)

#### Correctness
- Every `findById()` / `findAll()` throwing `NotFoundException`? (See `NotFoundException.product(id)`)
- Pagination off-by-one? `PageResponse.of(content, page, size, total)` — verify `first`/`last` flags
- Event handler effects happen only after `@TransactionalEventListener(AFTER_COMMIT)`?
- Sorting uses stable comparators? `ProductComparators` tested with equal-priority items?

#### Hexagonal Compliance
- Does `application/` import anything from `infrastructure/`? (ArchUnit rule 1 — will fail CI)
- Is the domain model free of JPA annotations? (`@Entity`, `@Table`, `@Column` — rule 2)
- Are ports returning `Optional<T>` instead of nullable? (Rule 3 — must NOT return `Optional`)
- Are FK columns stored as primitives (`Long`, `UUID`), not `@ManyToOne`/`@OneToMany`? (Rule 4)
- Are newly added domain services annotated `@Service`? (Rule 5)
- Are repository adapters annotated `@Component`? (Rule 6)

#### Test Quality
- Every `NotFoundException` thrown → test that asserts `assertThrows` + error code?
- Every bug fix → a test that **fails without the fix**?
- Over-mocked tests? Prefer `PageResponse.of(List.of(domain), 0, 20, 1)` over 3+ mock chains
- Test file location mirrors production code package? (e.g., `PriceServiceTest` in `price/application/domain/service/`)
- ArchUnit tests in `HexagonalArchitectureTest` still pass after structural changes?

#### Code Style & Java 21 Idioms
- Using `record` for DTOs instead of boilerplate classes?
- Using `Stream.toList()` (Java 16+) instead of `collect(Collectors.toList())`?
- Using `List.of()`, `Map.of()` for small immutable collections?
- Text blocks for multi-line SQL/JSON strings?
- `var` for obvious types (but not where it harms readability)?

### How to Give Feedback

**Good** (actionable, specific):
> "The `searchByProduct` method in `PriceService` has two branches — one for date range and one without. The test only covers the date-range path. Could you add a test for `startDate=null`, similar to how `StoreServiceTest` handles its null-criteria test?"

**Not helpful** (vague, unactionable):
> "This needs more tests."

**Better** (knowledge-sharing):
> "The `PageResponse.of()` static factory handles the math for `first`/`last` flags. I see you're setting these manually — use the factory instead. Here's the pattern used in `StoreServiceTest`."

### Review Flow

1. **Read the diff first** — understand intent before diving into implementation
2. **Check ArchUnit** — verify no structural violations introduced (CI runs this, but catch it early)
3. **Run tests locally**: `mvn verify -pl . -am` — never approve a PR without verifying it compiles and tests pass
4. **Check coverage impact**: `mvn jacoco:check` — verify new code doesn't drop below 80% INSTRUCTION / 80% BRANCH
5. **Spotless pass**: Ensure `mvn spotless:apply` was run — Google Java Style is enforced
6. **Event ordering**: If the PR touches `@TransactionalEventListener` handlers, verify the event flows don't introduce deadlocks or ordering issues across service boundaries

### When to Block vs. When to Approve

| Situation | Action |
|-----------|--------|
| ArchUnit rule violation | **Block** — CI will fail anyway |
| Missing `NotFoundException` on a find path | **Block** — introduces null risk to callers |
| Port returns `Optional<T>` | **Block** — violates project convention |
| Missing test for a new bug fix | **Block** — regression risk |
| Inefficient but correct code | **Approve with suggestion** — non-blocking improvement |
| Missing test for a happy path after full error path coverage | **Approve with suggestion** — acceptable trade-off |
| Minor style (formatting, naming) | **Approve with suggestion** — Spotless handles formatting automatically |

---

```bash
/skill token-optimize

```
- Focus on test files and coverage reports.

## lean-ctx Conventions

When using this skill:

- Use `lean-ctx ctx_read` for reading files (cached, compressed, ~13 tok for unchanged files)

- Use `lean-ctx ctx_edit` for edits needing context persistence

- Use `lean-ctx ctx_shell` for all shell commands (NOT the `bash` tool — it's denied in opencode.json)

- After completing work, persist any new patterns/gotchas discovered: `lean-ctx ctx_knowledge remember category <cat> key <key> value <value>`

