---
name: java-developer
description: Spring Boot hexagonal architecture, clean code, GoF design patterns, anti-patterns, modern Java 21, and quality gates (ArchUnit, SpotBugs, PMD CPD, Spotless)
license: MIT
compatibility: opencode
tags:
  - java
  - spring-boot
  - hexagonal-architecture
  - jpa
  - archunit
  - spotbugs
  - pmd
  - spotless
file_patterns:
  - "**/*.java"
  - "**/pom.xml"
metadata:
  role: developer
  framework: spring-boot
  java-version: "21"
triggers:
  - "hexagonal architecture"
  - "domain service"
  - "port interface"
  - "Spring Boot"
  - "JPA entity"
  - "ArchUnit"
  - "SpotBugs"
  - "PMD"
---

# Java Developer

## Architecture

```text
service-name/

├── application/

│   ├── domain/model/        ← @Builder @Getter @Setter, zero JPA

│   ├── domain/service/      ← @Service implements *InPort

│   ├── port/in/             ← Driving ports (XxxInPort)

│   ├── port/out/            ← Driven ports (XxxRepositoryPort, XxxEventOutPort)

│   └── exception/           ← Domain exceptions

└── infrastructure/

    ├── adapter/web/         ← @RestController + WebAdapter + *DtoMapper

    ├── adapter/persistence/ ← @Entity + RepositoryAdapter + JpaRepository + *Mapper

    ├── adapter/event/       ← Implements XxxEventOutPort

    └── handler/event/       ← @Async @TransactionalEventListener(AFTER_COMMIT)

```
## Data Shapes

| Shape | Type | Package |
|-------|------|---------|
| API DTO | `record` | `infrastructure/adapter/web/dto/` |
| Domain Model | `class` with `@Builder` | `application/domain/model/` |
| Entity | `class` with JPA | `infrastructure/adapter/persistence/entity/` |

## Rules

- NO `@ManyToOne`, `@OneToMany`, `@OneToOne`, `@ManyToMany`, `@JoinColumn`

- FK columns as primitives: `private UUID receiptId;`

- UUID `@Id`: `@GeneratedValue(strategy = GenerationType.UUID)`

- Long `@Id`: `@GeneratedValue(strategy = GenerationType.IDENTITY)`

- Ports return **nullable**, never `Optional<T>`

- Unwrap Spring Data `Optional` at adapter boundary

## Null Handling

```java
Objects.isNull(x)

Objects.nonNull(x)

StringUtils.isBlank(x)

ObjectUtils.defaultIfNull(x, fallback)

ObjectUtils.getOrNull(x, X::getY)

ObjectUtils.getOrDefault(x, X::getY, fallback)

ValidationUtils.requireNonNull(x, "name")

NumberUtils.toDouble(x)

JsonUtils.extractItems(json)

HashUtils.sha256(bytes)

```
## Exception Handling

- Custom exceptions in `application/exception/`: extend `RuntimeException`

- Messages from `ErrorMessageConstants`

- `@RestControllerAdvice` with `GlobalExceptionHandler`

- Use `ErrorCodes` for error codes

**Project exceptions:**

- `NotFoundException` → 404 (static factories: `price(id)`, `product(id)`, `receipt(id)`, `store(id)`)

- `IllegalArgumentException` → 400 (invalid inputs)

- `RateLimitExceededException` → 429

- `DuplicateReceiptException` → 409

- `Exception` → 500 (catch-all)

## Mapper Pattern

Every conversion in dedicated `*Mapper` / `*DtoMapper`. Never in adapters.

Naming: `*DtoMapper` (domain → API DTO), `*Mapper` (domain ↔ entity). Methods named `toXxx`.

**Project example:**

```java
@Component

@RequiredArgsConstructor

public class ProductDtoMapper implements DtoMapperSupport {

    public Product toApiProduct(ProductDomain domain, ProductPriceSummary summary) {

        return mapIfNotNull(domain, d -> {

            var result = new Product();

            result.setId(d.getId());

            result.setName(d.getName());

            result.setStatus(resolveStatusValue(d.getStatus()));

            return result;

        });

    }

}
```
## Controller Pattern

Controllers implement generated API interfaces from OpenAPI spec and delegate to WebAdapter:

```java
@RestController

@RequiredArgsConstructor

public class ProductController implements ProductsApi {

    private final ProductWebAdapter adapter;

    @Override

    public ResponseEntity<ControllerResponse<Product>> getProduct(Long id) {

        return ControllerResponse.ok(adapter.getProductById(id));

    }

}
```
**WebAdapter** converts API DTOs → domain, calls port, maps result back:

```java
@Component

@RequiredArgsConstructor

public class ProductWebAdapter {

    private final ProductInPort productInPort;

    private final ProductDtoMapper mapper;

    public Product getProductById(Long id) {

        ProductDomain domain = productInPort.findById(id);

        return mapper.toApiProduct(domain, null);

    }

}
```
## Event-Driven

- Domain service publishes via `XxxEventOutPort`

- Infrastructure adapter translates to Spring `ApplicationEvent`

- Handlers: `@TransactionalEventListener(phase = TransactionPhase.AFTER_COMMIT)` + `@Async`

- Never fire events outside a transaction

## Generic Service Abstraction

### AbstractGenericService Pattern

The project uses `AbstractGenericService<T, ID>` to centralize CRUD boilerplate. All 9 CRUD services extend it. Non-CRUD services (Admin, Shopping, LLM, etc.) do NOT.

**How to extend:**

```java
public class ProductService extends AbstractGenericService<ProductDomain, Long> implements ProductInPort {

    public ProductService(ProductRepositoryPort productRepository, ...) {

        super("Product", ErrorCodes.PRODUCT_NOT_FOUND);  // entityName + errorCode

    }

    @Override

    protected GenericRepositoryPort<ProductDomain, Long> getRepository() { return productRepository; }

    // Business methods only — CRUD inherited from parent

}
```
**Inherited methods:**

- `findById(ID id)` — throws `NotFoundException` when not found (with null guard)

- `save(T entity)` — persists + logs at debug level

- `findAll(PageRequestDto, String search, String status)` — paginated list

- `deleteById(ID id)` — validates existence via `findById()`, then deletes, logs at info level

### Inherited deleteById() — Context Check (GOTCHA)

⚠️ **Do NOT blindly recommend using inherited `deleteById()`.** The inherited method internally calls `findById()` for validation. If the calling context **already has the entity fetched** (e.g., via `findByHash()`, prior `findById()`), the inherited `deleteById()` performs a **redundant database round-trip**. Use `repository.deleteById(id)` directly instead.

**Check before recommending:**

| Context | Use |
|---------|-----|
| Entity NOT loaded in call chain | `this.deleteById(id)` (inherited) — validation useful |
| Entity IS loaded (verified non-null) | `repository.deleteById(id)` — avoid redundant findById |

### Annotation Loss on Override Removal (GOTCHA)

⚠️ When removing subclass overrides that simply delegate to `super`, audit for annotations present only on the override: `@Transactional`, `@ActivityLog`, `@Cacheable`. Removing the override removes those annotations.

**Mitigation:**

- `@Transactional` → move to parent method (PR #128 did this for `deleteById`)

- `@ActivityLog` → cannot be moved generically (domain-specific). Parent's `log.info()` provides adequate audit trail.

- `@Cacheable` → evaluate if caching still needed; annotate parent if cache key is generic

## Modern Java

```java
String.formatted()              // never String.format()

.toList()                       // never .collect(Collectors.toList())

.map(this::method)              // method reference over lambda

instanceof Foo f                // pattern matching

case X ->                       // switch expressions

```
## Writing Order

1. Port interface — `*InPort`, `*RepositoryPort`

2. Domain service — implements port, uses only domain models

3. Mapper — converts between shapes

4. Adapter — orchestration via ports + mappers

5. Constants — extract magic strings

6. Events — domain service publishes via `*EventOutPort`

## Build Gates

```bash
mvn test                    # Unit tests + ArchUnit (7 rules)

mvn verify                  # Full: tests + format + CPD + SpotBugs

mvn spotless:apply          # Auto-format (Google Java Style)

```
| Gate | Enforces |
|------|----------|
| **ArchUnit** | Hexagonal layers, no Optional in ports, no JPA in domain |
| **Spotless** | Google Java Format |
| **SpotBugs** | Null safety, encoding, exposed internals |
| **PMD CPD** | No duplicate code (>100 tokens) |
| **JaCoCo** | 90% INSTRUCTION / 80% BRANCH bundle coverage

### ArchUnit Rules

| Rule | Prevents |
|------|----------|
| `domainMustNotDependOnInfrastructure` | `application/` importing `infrastructure/` |
| `domainModelsMustNotHaveJpaAnnotations` | `@Entity`, `@Id`, `@Column` in domain POJOs |
| `portsMustNotReturnOptional` | `Optional<T>` in port return types |
| `entitiesMustNotUseJpaRelationshipAnnotations` | `@ManyToOne`, `@OneToMany`, etc. |
| `layeredArchitectureShouldRespectHexagonalBoundaries` | Reverse dependency direction |
| `domainServicesMustBeAnnotatedWithService` | Missing `@Service` |
| `repositoryAdaptersMustBeAnnotatedWithComponent` | Missing `@Component` |

### Page Format

```java
record PageRequest(int page, int size, String sortBy, String sortDirection) {}

record PageResponse<T>(List<T> content, int page, int size, long totalElements, int totalPages, boolean first, boolean last) {}

```
### Constants Files

- `AppConstants` — string/numeric/date constants

- `ErrorCodes` — error code identifiers

- `ErrorMessageConstants` — message templates

- `EntityConstants` — field names

- `ParamConstants` — request param names

- `SortConstants` — sort direction values

### Naming Conflicts

When API models conflict with domain models:

```text
API Model (external JAR):     Product          (keep simple name)

Domain Model (internal):      ProductDomain    (add "Domain" suffix)

Entity (database):            ProductEntity    (add "Entity" suffix)

```
- Never use fully qualified names inline

- Always add proper imports at the top

### Avoid Redundant Variables

**❌ BAD**

```java
var sorted = all.stream().sorted(comparator).toList();

all = sorted;  // Redundant

```
**✅ GOOD**

```java
all = all.stream().sorted(comparator).toList();

```
### No Unused Code (YAGNI)

- Functions never called

- Variables never used

- Parameters never referenced

- Dead code or commented-out code

**Exceptions:** Constants, utility functions, abstract/overridden methods.

## Companion Skills (Load on demand)

Load these when the task requires specialized Java/JVM knowledge beyond core hexagonal architecture.

### Framework
| /skill | Covers | Source |
|--------|--------|--------|
| `spring-boot-enterprise` | REST, JPA, Security, OAuth2, testing patterns | [piomin/claude-ai-spring-boot](https://github.com/piomin/claude-ai-spring-boot) |
| `spring-boot-4x` | Spring Boot 4.x patterns, virtual threads, GraalVM | [sivaprasadreddy/sivalabs-agent-skills](https://github.com/sivaprasadreddy/sivalabs-agent-skills) |
| `restart-spring-boot` | Spring Boot restart & hot-reload patterns | [jvm-skills/jvm-skills](https://github.com/jvm-skills/jvm-skills) |

### Language
| /skill | Covers | Source |
|--------|--------|--------|
| `java-streams` | Streams API, Collectors, Gatherers, parallel streams | [martinfrancois/java-streams-skill](https://github.com/martinfrancois/java-streams-skill) |
| `java-optional` | Optional patterns, antipatterns, best practices | [martinfrancois/java-optionals-skill](https://github.com/martinfrancois/java-optionals-skill) |
| `java-code-quality` | Code review, SOLID, clean code, anti-patterns | [piomin/claude-ai-spring-boot](https://github.com/piomin/claude-ai-spring-boot) |
| `java-design-patterns` | GoF patterns, Java idioms, refactoring | [piomin/claude-ai-spring-boot](https://github.com/piomin/claude-ai-spring-boot) |
| `java-logging-patterns` | SLF4J, Logback, structured logging, MDC | [piomin/claude-ai-spring-boot](https://github.com/piomin/claude-ai-spring-boot) |
| `jspecify-nullability` | JSpecify annotations, null-safety contracts | [sivaprasadreddy/sivalabs-agent-skills](https://github.com/sivaprasadreddy/sivalabs-agent-skills) |

### Database
| /skill | Covers | Source |
|--------|--------|--------|
| `jpa-hibernate-patterns` | N+1 prevention, lazy loading, @EntityGraph, batch fetching | [piomin/claude-ai-spring-boot](https://github.com/piomin/claude-ai-spring-boot) |
| `jooq-best-practices` | jOOQ type-safe queries, code generation, DSL | [jvm-skills/jvm-skills](https://github.com/jvm-skills/jvm-skills) |
| `postgres-table-design` | PostgreSQL schema design, indexing, partitioning | [timescale/pg-aiguide](https://github.com/timescale/pg-aiguide) |
| `pgvector-search` | pgvector semantic search, embeddings, similarity | [timescale/pg-aiguide](https://github.com/timescale/pg-aiguide) |
| `postgres-text-search` | Full-text search, hybrid search, tsvector | [timescale/pg-aiguide](https://github.com/timescale/pg-aiguide) |

### Testing
| /skill | Covers | Source |
|--------|--------|--------|
| `mutation-testing` | pitest, mutation testing, test quality assessment | [jvm-skills/jvm-skills](https://github.com/jvm-skills/jvm-skills) |
| `coverage-kover-gradle` | Kover Gradle plugin, coverage reports, thresholds | [jvm-skills/jvm-skills](https://github.com/jvm-skills/jvm-skills) |
| `ralph-coverage` | Ralph coverage analysis, test gap detection | [jvm-skills/jvm-skills](https://github.com/jvm-skills/jvm-skills) |
| `gradle-test-runner` | Gradle test execution, filtering, parallel runs | [jvm-skills/jvm-skills](https://github.com/jvm-skills/jvm-skills) |
| `jdb-debugger` | JDB agentic debugging, breakpoints, inspection | [brunoborges/jdb-agentic-debugger](https://github.com/brunoborges/jdb-agentic-debugger) |

### Workflow
| /skill | Covers | Source |
|--------|--------|--------|
| `commit` | Conventional commits, atomic commits, commit messages | [jvm-skills/jvm-skills](https://github.com/jvm-skills/jvm-skills) |
| `rebase-commit` | Interactive rebase, squash, commit cleanup | [jvm-skills/jvm-skills](https://github.com/jvm-skills/jvm-skills) |
| `spec` | Specification writing, requirements, acceptance criteria | [jvm-skills/jvm-skills](https://github.com/jvm-skills/jvm-skills) |

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

