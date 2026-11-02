---
name: security-expert
description: Security — vulnerability assessment, threat modeling, secure coding review, and compliance checking
license: MIT
compatibility: opencode
tags:
  - security
  - threat-modeling
  - owasp
  - vulnerability
  - authentication
  - authorization
file_patterns:
  - "**/*.java"
  - "**/*.yml"
  - "**/pom.xml"
metadata:
  role: security
  domain: engineering
triggers:
  - "vulnerability"
  - "threat model"
  - "OWASP"
  - "security review"
  - "CVE"
  - "authentication"
---

# Security Expert

## Project Exception Handling Pattern

All exceptions flow through `GlobalExceptionHandler` (`@RestControllerAdvice`):

- `NotFoundException` → **404** with specific error code (e.g. `PRODUCT_NOT_FOUND`, `PRICE_NOT_FOUND`)

- `IllegalArgumentException` → **400**

- `ConstraintViolationException`, `MethodArgumentNotValidException` → **400** with field-level messages

- `RateLimitExceededException` → **429** with `Retry-After` and rate limit headers

- `DuplicateReceiptException` → **409** (CONFLICT)

- `MethodArgumentTypeMismatchException`, `HttpMessageNotReadableException` → **400**

- Unhandled `Exception` → **500** (logged with stack trace, no internal details leaked to response)

**Rule**: Never expose internal implementation details in error responses. Use error codes (`ErrorCodes.PRODUCT_NOT_FOUND`) not stack traces.

## Input Validation (Project Patterns)

- **LLM provider validation**: `LlmProviderType.fromValue()` null/blank-safe, defaults to `LOCAL` for unknown values — safe fallback, never throws on bad input

- **Null handling**: Use `Objects.isNull()`, `StringUtils.isBlank()`, `ValidationUtils.requireNonNull()` — no raw null checks

- **Ports return nullable**, not `Optional<T>` — callers must handle null explicitly

- **Domain services** throw `NotFoundException` (static factories) when resources not found — never return null

## Secrets & Configuration

- API keys in `application.yml` externalized — use `${ENV_VAR:default}` pattern for environment variable overrides

- **No secrets in code**: never hardcode tokens, passwords, or API keys in Java files

- `.env` is gitignored — secrets go there or in environment variables

- GitHub Packages auth via `~/.m2/settings.xml` with personal access token (PAT), never in pom.xml

## Data Protection

- Encrypt in transit (TLS 1.2+) enforced at load balancer/reverse proxy level

- No PII or tokens in logs — `GlobalExceptionHandler` logs the exception but never the request body

- Rate limiting via `RateLimitExceededException` — prevents abuse on receipt/price endpoints

## Dependency Security

- `mvn verify -P security-check` runs OWASP dependency-check plugin

- All dependencies from Maven Central or GitHub Packages with verified checksums

- `goods-price-comparison-api` dependency from GitHub Packages — verify token has least privilege

## Common Vulnerabilities to Check

- SQL injection: this project uses Spring Data JPA (parameterized queries) — verify custom `@Query` annotations don't concatenate

- Rate limit bypass: test that `RateLimitExceededException` headers are properly enforced

- Access control: verify users can't access other users' receipts without authorization

- Config leakage: verify `application.yml` doesn't contain real secrets, only `${...}` references

---

## OWASP Top 10 Prevention Patterns

Prevention patterns adapted from the [OWASP Top 10:2021](https://owasp.org/Top10/) for this project's Java 21 + Spring Boot 3.4 hexagonal architecture. These are not theoretical — each maps to a concrete check in pre-merge review.

### A01: Broken Access Control

Access control enforcement follows the **hexagonal boundary pattern**: the port interface defines who *can* call what, and the domain service enforces *under what conditions*.

- **Resource ownership checks live in domain services** — controllers never check "is this receipt yours?". The domain service receives the authenticated principal and validates ownership.
- **Service-layer enforcement**: `ReceiptService.findReceiptForUser(receiptId, userId)` — the domain service throws `NotFoundException` (→ 404) if the resource doesn't exist OR doesn't belong to the caller. Attackers cannot distinguish "not found" from "not yours".
- **No controller-level authorization logic** — controllers delegate. If a controller contains `if (principal.equals(...))`, that's a code review flag.
- **Ports define scope, not permissions**: `ReceiptRepositoryPort.findByUserId(userId)` — the query is scoped, so the caller never receives data they shouldn't see.
- **Spring Security future-proofing**: if Spring Security is added, use `@PreAuthorize` at the service layer, not in controllers. Method security on ports creates a single enforcement point.

### A02: Cryptographic Failures

Encryption and secret management follow **environment-first, code-never** rules:

- **TLS 1.2+** is enforced at the load balancer / reverse proxy. The application should not serve plain HTTP in production.
- **Passwords**: use `BCryptPasswordEncoder` (Spring Security) or `SCryptPasswordEncoder` — minimum 12 salt rounds. Never MD5, SHA-1, or custom hashing.
- **Secrets rotation**: if a secret is ever committed, rotate it immediately. Deleting the line is not enough — assume compromise from the moment it reaches a remote.
- **Data at rest**: sensitive database columns (if any) should use column-level encryption (`@Column(columnDefinition = ...)` with PostgreSQL `pgcrypto`) or application-layer encryption before persisting.
- **No crypto in application/domain layer**: encryption libraries belong in `infrastructure/adapter/`. Domain models are pure Java with `@Builder @Getter @Setter` — no crypto annotations.

### A03: Injection (SQL, NoSQL, Command)

Spring Data JPA provides parameterized queries by default, but custom `@Query` annotations and native queries need scrutiny:

- **Parameterized queries are mandatory**: every `@Query` must use `:namedParameter` or `?positional` syntax. Never string concatenation or `+` in query strings.
  ```java
  // BAD
  @Query("SELECT p FROM Price p WHERE p.productId = " + productId)
  // GOOD
  @Query("SELECT p FROM Price p WHERE p.productId = :productId")
  List<Price> findByProductId(@Param("productId") String productId);
  ```
- **Native queries are a red flag**: `@Query(value = "...", nativeQuery = true)` bypasses JPA's escaping. If native SQL is unavoidable, wrap parameters with `param` binding only — never `#{}` or string interpolation.
- **Specification/Example queries**: preferred over dynamic JPQL. Use `JpaSpecificationExecutor` for dynamic filters — it's parameterized by construction.
- **LLM-generated queries**: if an LLM produces JPQL (e.g., natural-language-to-query features), the output MUST be schema-validated against an allowlist of table/column names before execution. Treat LLM output as untrusted input.
- **No raw JDBC**: if `JdbcTemplate` or `EntityManager.createNativeQuery()` is used, verify every parameter uses `setParameter()`. This is a SpotBugs candidate.

### A04: Insecure Design

Most breaches originate in design, not code. The hexagonal architecture is itself a security control:

- **Trust boundaries align with package boundaries**:
  - `application/domain/` — pure logic, no I/O. Cannot be exploited via network.
  - `application/port/in/` — driving ports (what the app does). The security contract.
  - `application/port/out/` — driven ports (what the app needs). Spi for repositories/events.
  - `infrastructure/adapter/web/` — the attack surface. Must validate before passing to domain.
  - `infrastructure/adapter/persistence/` — the data boundary. Must not leak domain concerns.
- **ArchUnit enforces the boundaries**: `application/` cannot import `infrastructure/`. This isolates the attack surface — even if a web adapter is compromised, the domain remains intact.
- **Threat model per feature**: before implementing a new port, run a lightweight STRIDE:
  - Can an unauthenticated caller invoke this? → Add auth check.
  - Can data be tampered between port and adapter? → Validate in the adapter before domain.
  - Can a failure in this service cascade? → Use `@Async` + `@TransactionalEventListener(AFTER_COMMIT)` — events are fire-and-forget, not in the request path.
- **Abuse cases next to use cases**: for every API endpoint, write "how would I misuse this?" — then make that your first test case.

### A05: Security Misconfiguration

Configuration drift is the most common finding in production audits.

- **CORS**: if enabled, restrict origins explicitly — no `allowedOrigins("*")`. Use `${CORS_ALLOWED_ORIGINS:http://localhost:3000}` as an environment-driven allowlist.
- **Security headers**: if using Spring Security, configure headers via `HttpSecurity.headers()` — at minimum `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Cache-Control: no-store` for authenticated endpoints.
- **Error responses**: `GlobalExceptionHandler` maps every exception class to a safe HTTP status. Never return `e.getMessage()` for unhandled exceptions — only the `ErrorCodes` constant.
- **Actuator endpoints**: if Spring Boot Actuator is enabled, restrict to admin-only via `management.endpoints.web.exposure.include=` and `management.endpoints.web.base-path=/internal`. Never expose `/actuator/env` or `/actuator/beans` publicly.
- **Profile-aware config**: `application-test.yml` uses H2 with Flyway disabled. Verify production profiles don't accidentally include test-only config via `spring.profiles.active`.
- **H2 console**: must be disabled in production profiles. A rogue H2 console is a remote code execution vector.

### A06: Vulnerable Components

Supply-chain risk is managed through build gates and dependency hygiene:

- **`mvn verify -P security-check`** runs OWASP Dependency-Check. This is a PR gate, not optional. If it fails, fix or document the CVE before merging.
- **Dependency sources**: Maven Central + GitHub Packages only. No custom repositories, no SNAPSHOT dependencies from untrusted sources.
- **`goods-price-comparison-api`** from GitHub Packages: verify the GitHub token used in `~/.m2/settings.xml` has **read-only** package access (least privilege). Never use a PAT with write scope for dependency resolution.
- **Plugin versions**: SpotBugs (4.9.x), PMD (7.x), Spotless (2.43.x) — keep updated via `mvn versions:display-plugin-updates`. Known CVEs in build plugins can compromise CI.
- **Transitive dependencies**: run `mvn dependency:tree -Dincludes=*:*:*:*-SNAPSHOT` before release. No SNAPSHOT dependencies in production builds.
- **SBOM generation**: consider adding `cyclonedx-maven-plugin` to generate a Software Bill of Materials for each release. This enables CVE matching against what's actually deployed.

### A07: Identification & Authentication Failures

This project uses **stateless auth** patterns (no session management yet). Current and planned protections:

- **Rate limiting on auth-adjacent endpoints**: `RateLimitExceededException` → 429 with `Retry-After` header. Prevents brute-force on any endpoint that takes user identity input.
- **No user enumeration**: error messages are consistent whether a user exists or not. `NotFoundException("RECEIPT_NOT_FOUND")` doesn't hint whether the receipt or the user was the problem.
- **Password strength**: if user-registration is added, enforce minimum complexity via `@Pattern` or a custom validator. Spring Boot's `spring-boot-starter-validation` provides the annotations.
- **Token management**: if JWT is added, tokens must be short-lived (15 minutes access, 7 days refresh), stored in `httpOnly`/`secure`/`SameSite=Strict` cookies (never `localStorage`), and revoked server-side on logout.
- **Session fixation**: if `HttpSession` is used, call `session.changeSessionId()` after authentication.
- **Account lockout**: after N failed login attempts (configurable via `application.yml`), apply an exponential backoff before allowing retry.

### A08: Software & Data Integrity

Integrity spans build, deploy, and runtime data flows:

- **Checksum verification**: Maven downloads with checksum verification enabled (`<checksumPolicy>fail</checksumPolicy>` in `settings.xml`). Corrupted artifacts fail the build.
- **GitHub Packages trust**: `goods-price-comparison-api` is published by the same org — verify the package is signed or has a matching checksum. Never pull packages from unknown publishers.
- **Pipeline integrity**: CI/CD (if configured) must use pinned action/plugin versions by commit SHA, not by float tag (e.g., `actions/checkout@v4` → `actions/checkout@a12b3c...`). Tag-based references can be overwritten.
- **Event integrity**: `@Async @TransactionalEventListener(AFTER_COMMIT)` events carry domain data. Event payloads should not be mutable after creation — domain models are `@Builder` with no setters for identity fields.
- **No in-place mutation**: domain models use `@Setter` but identity fields (IDs, timestamps) should be set at construction only. Adapter code must not modify domain objects after they're persisted.

### A09: Security Logging & Monitoring

Logs are the primary detection mechanism. Misconfigured logging is a monitoring blind spot.

- **No PII in logs**: `GlobalExceptionHandler` logs the exception class, message, and stack trace — never request headers, body, or parameters. This is enforced by convention and code review.
- **Structured logging**: use `MDC` (Mapped Diagnostic Context) to correlate requests:
  ```java
  MDC.put("requestId", requestId);
  MDC.put("userId", authenticatedUserId);  // not the user's email
  log.warn("Rate limit exceeded for userId={}", userId);
  MDC.clear();
  ```
- **Audit events for security-sensitive operations**:
  - Authentication failures (wrong password, expired token)
  - Authorization denials (accessing another user's resource)
  - Rate limit triggers
  - Configuration changes
- **Log levels by severity**:
  - `ERROR`: 5xx, unexpected exceptions, security breaches
  - `WARN`: 4xx, rate limiting, validation failures, deprecated API usage
  - `INFO`: service startup/shutdown, successful authentication, config changes
  - `DEBUG`: detailed flow tracing (never in production by default)
- **Never log**: passwords, tokens, API keys, full JWT payloads, credit card data, `request.getBody()`.
- **Alerting**: monitor `WARN`+ logs for rate-limit triggers and auth failures — these are the earliest indicators of an attack in progress.

### A10: Server-Side Request Forgery (SSRF)

SSRF risk exists wherever the application fetches a URL influenced by user input — webhooks, LLM callbacks, external product data, receipt image URLs.

- **URL allowlist**: maintain a strict allowlist of permitted hosts/schemes for outbound requests. Reject anything not on the list.
  ```java
  // Acceptable: Set.of("api.openai.com", "hooks.example.com")
  // Reject: localhost, 127.0.0.1, 10.x, 172.16-31.x, 192.168.x, metadata endpoints
  ```
- **Protocol restriction**: enforce `https://` only. Reject `http://`, `file://`, `ftp://`, `gopher://` — the latter is a documented SSRF vector.
- **DNS rebinding protection**: resolve the hostname BEFORE connecting and verify the resolved IP is not private:

  ```java
  import java.net.InetAddress;
  
  private InetAddress resolveAndCheck(String host) {
      InetAddress[] addresses = InetAddress.getAllByName(host);
      for (InetAddress addr : addresses) {
          if (addr.isSiteLocalAddress() || addr.isLoopbackAddress()
              || addr.isLinkLocalAddress() || addr.isAnyLocalAddress()) {
              throw new IllegalArgumentException("Blocked private IP: " + addr);
          }
      }
      return addresses[0]; // Pin to first resolved address
  }
  ```
- **Redirect blocking**: configure HTTP clients to NOT follow redirects (`HttpClient.newBuilder().followRedirects(HttpClient.Redirect.NEVER)`). A redirect can bypass the initial URL validation.
- **Rate limit outbound requests**: even SSRF-safe code should apply rate limiting to outbound calls to prevent the application from being used as a DoS amplifier.
- **The `feign.Client` risk (if Feign is used)**: ensure Feign clients that accept dynamic URLs use the same validation above. A misconfigured Feign client is a blind SSRF vector.

**Project-specific note**: LLM provider calls (`LlmProviderType.fromValue()`) route through adapters with fixed base URLs. If dynamic provider URLs are ever added, apply SSRF validation at the port boundary.

---

## Anti-Rationalization Table

| Rationalization | Reality |
|---|---|
| "This is an internal service, security doesn't matter" | Internal services get compromised. Attackers pivot through the weakest link. |
| "We'll add security later" | Retrofitting security costs 10x more. Build it into the hexagonal boundaries from day one. |
| "Spring Data JPA prevents SQL injection" | It prevents concatenation in `findBy*` methods. Custom `@Query` annotations with string concatenation bypass that protection. |
| "No one would try to exploit rate limits" | Bots scan for unauthenticated endpoints. Without rate limiting, every endpoint is a DoS amplifier. |
| "The error code is vague, that's enough" | Even vague errors can leak information if they differentiate "user not found" from "wrong password" for the same input. |
| "We only run trusted dependencies" | Trusted dependencies have CVEs too. OWASP dep-check catches known vulnerabilities in transitive dependencies you didn't vet. |
| "Threat modeling is overkill for a microservice" | Five minutes of "how would I attack this?" catches design flaws that no amount of code review can fix. |
| "LLM providers handle security" | LLM providers handle their side of the boundary. Your side — prompt injection, data leakage in context, output validation — is your responsibility. |
| "Stack traces only show in dev mode" | One misconfigured profile and production leaks internals. Generic error responses are the default for all profiles. |
| "Nobody uses this endpoint anymore" | Unused endpoints are the most common source of unpatched vulnerabilities. Remove or gate them. |
| "We validate on the frontend, that's enough" | Client-side validation is a courtesy, not a security boundary. Every API endpoint must validate independently. |

---

## Security Review Checklist

Pre-merge checklist aligned with project conventions and ArchUnit rules. Run this before every PR.

### Architecture & Design (ArchUnit-enforced)
- [ ] `application/` has no imports from `infrastructure/` — verified by ArchUnit rule
- [ ] Ports return nullable types, never `Optional<T>` — caller must handle null
- [ ] Domain services annotated with `@Service`, repository adapters with `@Component`
- [ ] No JPA annotations (`@Entity`, `@ManyToOne`, etc.) in `application/domain/model/`
- [ ] No relationship annotations (`@OneToMany`, `@JoinColumn`) anywhere — FKs are primitives
- [ ] Events fire only after transaction commit (`@TransactionalEventListener(AFTER_COMMIT)`)

### Access Control
- [ ] Every endpoint that accesses user-specific data checks ownership in the domain service
- [ ] No controller contains authorization logic — all in domain service
- [ ] `NotFoundException` returned for both "not found" and "not yours" (no user enumeration)
- [ ] Admin endpoints (if any) verify admin role before any data access

### Input Validation & Injection
- [ ] All custom `@Query` annotations use `:param` syntax — no `+` concatenation
- [ ] Native queries (`nativeQuery = true`) have an explicit justification comment
- [ ] All request DTOs use `@jakarta.validation.constraints` annotations
- [ ] No raw `JdbcTemplate` or `EntityManager.createNativeQuery()` without parameter binding
- [ ] LLM-generated queries (if used) are schema-validated before execution

### Configuration & Secrets
- [ ] No secrets in Java files or committed `application.yml` — only `${ENV_VAR:default}` references
- [ ] CORS origins restricted to explicit allowlist — no `allowedOrigins("*")`
- [ ] H2 console disabled in production profiles
- [ ] Actuator endpoints (if enabled) restricted to `/internal/*` with admin access
- [ ] `.env` is in `.gitignore` — no committed env files
- [ ] GitHub Packages token has read-only scope in `~/.m2/settings.xml`

### Data Protection & SSRF
- [ ] No PII, tokens, or request bodies in log output
- [ ] `GlobalExceptionHandler` returns only error codes for unhandled exceptions — never `e.getMessage()`
- [ ] HTTP client configured with `followRedirects(NEVER)` and protocol restriction (`https://`)
- [ ] Outbound URL fetches validated against an allowlist (SSRF prevention)
- [ ] Rate limiting applied to auth-adjacent and outbound endpoints

### Dependency & Supply Chain
- [ ] `mvn verify -P security-check` passes (OWASP Dependency-Check) — or CVEs documented with review date
- [ ] No SNAPSHOT dependencies in production build (`mvn dependency:tree -Dincludes=*:*:*:*-SNAPSHOT`)
- [ ] New dependencies reviewed: maintenance activity, download counts, known CVEs
- [ ] `mvn spotless:apply` run (formatting enforced at build gate)

### Logging & Monitoring
- [ ] Security-sensitive operations logged at appropriate level (auth failures → WARN, 5xx → ERROR)
- [ ] MDC used for correlation (`requestId`, `userId` — not email or name)
- [ ] No `System.out.println()` or `printStackTrace()` — use SLF4J logger
- [ ] `application.yml` has correct log level for production (`root: WARN`, security package: `INFO`)

### Testing
- [ ] ArchUnit tests pass (7 rules)
- [ ] Unit tests cover access-control scenarios (user A cannot access user B's data)
- [ ] Rate-limiting boundary tested (429 response with headers)
- [ ] Error scenarios tested: invalid IDs return 400/404, not 500

---

## Token Optimization

```bash
/skill token-optimize

```
- Focus on security-sensitive files (auth, validation, data handling).

## lean-ctx Conventions

When using this skill:

- Use `lean-ctx ctx_read` for reading files (cached, compressed, ~13 tok for unchanged files)

- Use `lean-ctx ctx_edit` for edits needing context persistence

- Use `lean-ctx ctx_shell` for all shell commands (NOT the `bash` tool — it's denied in opencode.json)

- After completing work, persist any new patterns/gotchas discovered: `lean-ctx ctx_knowledge remember category <cat> key <key> value <value>`

