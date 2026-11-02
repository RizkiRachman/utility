---
name: test-driven-development
description: Writes tests before production code. Uses tests to drive API design and verify correctness.
---

# Test-Driven Development

**Red → Green → Refactor.** Write the test that defines the behavior *before* writing the code that satisfies it.

---

## 1. The Red-Green-Refactor Cycle

### 🔴 Red — Write a failing test first

Define the method signature and expected behavior before any implementation.

```java
@ExtendWith(MockitoExtension.class)
class ProductLookupServiceTest {

  @Mock private ProductRepositoryPort productRepository;
  @InjectMocks private ProductLookupService service;

  @Test
  @DisplayName("Should return product when found by name")
  void shouldReturnProductWhenFoundByName() {
    var product = ProductDomain.builder()
        .id(1L).name("Susu Kotak").category("Minuman").build();
    when(productRepository.findByName("Susu Kotak")).thenReturn(product);

    var result = service.findByName("Susu Kotak");

    assertNotNull(result);
    assertEquals("Susu Kotak", result.getName());
    verify(productRepository).findByName("Susu Kotak");
  }
}
```

This test won't compile yet — `ProductLookupService.findByName()` doesn't exist. **That's the point.** The test drives you to create it.

### 🟢 Green — Write minimal code to pass

```java
@Service
public class ProductLookupService implements ProductLookupInPort {

  private final ProductRepositoryPort productRepository;

  @Override
  public ProductDomain findByName(String name) {
    return productRepository.findByName(name);
  }
}
```

**Minimal.** No validation, no error handling, no logging. Just enough to turn the test green.

### 🔵 Refactor — Clean up while tests stay green

```java
@Override
public ProductDomain findByName(String name) {
  var product = productRepository.findByName(name);
  if (product == null) {
    throw NotFoundException.product(name);
  }
  log.debug("Found product: {} ({})", product.getId(), product.getName());
  return product;
}
```

Run the test after each change. If it breaks, you went too far — revert and redo.

---

## 2. Writing Order in TDD (Maps to Hexagonal)

| Step | What You Write First | What the Test Proves |
|------|---------------------|----------------------|
| 1 | Port interface (`*InPort`, `*RepositoryPort`) | Compilation — signatures must exist |
| 2 | **Failing test** that uses the port | Desired behavior is defined |
| 3 | Domain service (minimal impl) | Test turns green |
| 4 | Mapper tests (domain ↔ entity, domain ↔ DTO) | Conversion logic is correct |
| 5 | Adapter tests (web/persistence) | Orchestration wiring is correct |
| 6 | Exception/edge-case tests | Resilience is verified |

**Key insight**: When you write the test before the service, you're designing the API from the consumer's perspective. The test is your first client.

---

## 3. When to TDD — Decision Framework

| Scenario | TDD? | Why |
|----------|------|-----|
| New domain service method | ✅ **Always** | Core behavior, drives clean API design |
| Bug fix | ✅ **Always** | Write regression test first — proves the bug exists, proves the fix works |
| Mapper conversion logic | ✅ **Always** | Trivial to test, expensive if wrong |
| Controller/WebAdapter | ✅ **Usually** | Validates request → domain → response flow |
| Event handler | ✅ **Usually** | Verify event is consumed and side effects happen |
| Configuration class | ⚠️ **Skip** | No behavior to drive — test via `@WebMvcTest` or integration test |
| JPA repository query | ⚠️ **Integration test** | `@DataJpaTest` tests the query directly — no TDD cycle needed |
| Build/CI config | ❌ **Skip** | Not testable via JUnit |
| One-line delegate method | ❌ **Skip** | Test the caller instead — don't test getters/setters/trivial delegates |

**Rule of thumb**: If the method has a branch, a loop, a null check, or a calculation — TDD it.

---

## 4. Test Patterns

### 4.1 Arrange-Act-Assert (AAA)

Separate each phase with blank lines:

```java
@Test
void shouldReturnProductWhenFoundByName() {
  // Arrange
  var expected = ProductDomain.builder().id(1L).name("Susu Kotak").build();
  when(productRepository.findByName("Susu Kotak")).thenReturn(expected);

  // Act
  var result = service.findByName("Susu Kotak");

  // Assert
  assertNotNull(result);
  assertEquals("Susu Kotak", result.getName());
  verify(productRepository).findByName("Susu Kotak");
}
```

### 4.2 Test Naming Conventions

Use `should<ExpectedBehavior>When<Condition>` — reads as a sentence:

| Name | What It Tests |
|------|---------------|
| `shouldReturnProductWhenFoundByName` | Happy path |
| `shouldThrowNotFoundWhenProductMissing` | Error path |
| `shouldNotSaveWhenProductAlreadyExists` | Idempotency |
| `shouldFilterByStatusAndCategory` | Multiple criteria |

### 4.3 One Assert Concept vs Scenario Tests

**One assert concept per test** — verify one logical behavior:

```java
// ✅ GOOD — one concept: null on not found
@Test
void shouldReturnNullWhenProductNotFound() {
  when(productRepository.findByName("unknown")).thenReturn(null);

  var result = service.findByName("unknown");

  assertNull(result);
}

// ✅ GOOD — separate test for found case
@Test
void shouldReturnProductWhenFound() {
  // ...
}
```

**Scenario test** — multiple asserts that verify one *scenario* are fine:

```java
// ✅ ACCEPTABLE — all asserts verify different aspects of "create store"
@Test
void shouldCreateStoreWithAllFields() {
  var result = storeService.create(criteria);

  assertNotNull(result);
  assertEquals("Toko Segar", result.getName());
  assertEquals("Jakarta", result.getLocation());
  assertEquals("ACTIVE", result.getStatus());
  verify(storeRepository).save(any(StoreDomain.class));
}
```

**Never** mix happy-path and error-path assertions in the same test.

---

## 5. Mocking Strategies

### 5.1 What to Mock

Mock **ports** (boundaries), not domain logic:

```java
// ✅ GOOD — mock the repository port
@Mock private StoreRepositoryPort storeRepository;
@Mock private ProductPriceQueryInPort productPriceQueryInPort;

// ❌ BAD — mocking a domain service
@Mock private StoreService storeService;  // Don't mock the class under test
```

### 5.2 Verify Interactions

Use `verify()` to prove the service called the right methods with the right arguments:

```java
// Verify exact arguments
verify(storeRepository).save(storeCaptor.capture());
assertEquals("Toko Segar Baru", storeCaptor.getValue().getName());

// Verify never called
verify(productRepository, never()).save(any());

// Verify exactly N calls
verify(productRepository, times(2)).save(any(ProductDomain.class));
```

### 5.3 Stubbing Patterns

```java
// Simple return
when(repository.findById(1L)).thenReturn(product);

// Sequential returns (first call, second call)
when(repository.findAll()).thenReturn(List.of(p1), List.of(p1, p2));

// Dynamic answer
when(repository.save(any())).thenAnswer(inv -> {
  var p = inv.<ProductDomain>getArgument(0);
  if (p.getId() == null) p.setId(1L);
  return p;
});

// Void methods
doNothing().when(eventPublisher).publish(any());
```

### 5.4 Capturing Arguments

Use `@Captor` for precise argument assertions:

```java
@Captor private ArgumentCaptor<ProductDomain> productCaptor;

@Test
void shouldSaveProductWithGeneratedId() {
  service.create(input);

  verify(productRepository).save(productCaptor.capture());
  var saved = productCaptor.getValue();
  assertNull(saved.getId());  // ID is null before save
}
```

---

## 6. Testing Edge Cases via TDD

### 6.1 Null Inputs (Ports return nullable, never Optional)

```java
@Test
void shouldThrowNotFoundWhenIdIsNull() {
  assertThrows(IllegalArgumentException.class, () -> service.findById(null));
}

@Test
void shouldThrowNotFoundWhenProductMissing() {
  when(productRepository.findById(999L)).thenReturn(null);

  var exception = assertThrows(NotFoundException.class,
      () -> service.findById(999L));

  assertEquals("PRODUCT_NOT_FOUND", exception.getErrorCode());
}
```

### 6.2 Boundary Conditions

```java
@Test
void shouldReturnEmptyListWhenNoResults() {
  var criteria = ProductSearchCriteria.builder().search("XXX").page(0).size(20).build();
  when(productRepository.search(criteria)).thenReturn(PageResponse.empty());

  var result = service.search(criteria);

  assertTrue(result.content().isEmpty());
  assertEquals(0, result.totalElements());
}

@Test
void shouldHandleMaxPageSize() {
  var criteria = ProductSearchCriteria.builder().page(0).size(1000).build();
  // Test that the service clamps or passes through correctly
  service.search(criteria);
  verify(productRepository).search(criteria);
}
```

### 6.3 Error Paths (Exceptions)

```java
@Test
void shouldPropagateRepositoryException() {
  when(productRepository.findById(1L)).thenThrow(new DataAccessException("DB down"));

  assertThrows(DataAccessException.class, () -> service.findById(1L));
}
```

---

## 7. TDD Anti-Patterns

### ❌ Testing Implementation Details

**Bad** — tests how, not what:
```java
// ❌ BAD — tests internal structure
@Test
void shouldUseHashMapInternally() {
  assertTrue(service.getCache() instanceof HashMap);
}
```

**Good** — tests behavior:
```java
// ✅ GOOD — tests observable behavior
@Test
void shouldReturnCachedResultOnSecondCall() {
  service.findByName("Susu");
  service.findByName("Susu");
  verify(repository, times(1)).findByName("Susu");
}
```

### ❌ Fragile Tests (Tight Coupling to Wiring)

```java
// ❌ BAD — breaks if you rename or reorder parameters
verify(repository).save(argThat(p -> p.getName().equals("X")));
```

```java
// ✅ GOOD — explicit capture, readable assertion
verify(repository).save(captor.capture());
assertEquals("X", captor.getValue().getName());
```

### ❌ Over-Mocking

```java
// ❌ BAD — mocking a value object
var product = mock(ProductDomain.class);
when(product.getName()).thenReturn("Susu");  // Useless — just build one
```

```java
// ✅ GOOD — build real domain objects
var product = ProductDomain.builder().id(1L).name("Susu").build();
```

**Rule**: Never mock domain models, DTOs, or value objects. Use `.builder()`.

### ❌ Testing Through Multiple Layers

```java
// ❌ BAD — tests controller through full Spring context for simple logic
@SpringBootTest
void testController() { ... }

// ✅ GOOD — unit test the WebAdapter + integration test the controller
@ExtendWith(MockitoExtension.class)
class WebAdapterTest { ... }

@WebMvcTest(Controller.class)
class ControllerWebMvcTest { ... }
```

---

## 8. TDD in This Project — Project-Specific Patterns

### 8.1 AbstractGenericServiceTest

CRUD services extend `AbstractGenericServiceTest` which provides inherited tests for `findById`, `deleteById`:

```java
class StoreServiceTest extends AbstractGenericServiceTest {

  @Override protected Object getExistingId() { return 1L; }
  @Override protected Object getNonExistentId() { return 999L; }
  @Override protected String getNotFoundErrorCode() { return "STORE_NOT_FOUND"; }
  @Override protected void mockFindByIdReturnsEntity() { when(repo.findById(1L)).thenReturn(store1); }
  @Override protected void mockFindByIdReturnsNull() { when(repo.findById(999L)).thenReturn(null); }
  // ... custom business tests below
}
```

### 8.2 NotFoundException Testing

Implement `ServiceLayerNotFoundExceptionTest` for automated `NotFoundException` validation:

```java
class ProductServiceTest extends AbstractGenericServiceTest
    implements ServiceLayerNotFoundExceptionTest {

  @Override
  public void mockRepositoryReturnsNull() {
    when(productRepository.findById(999L)).thenReturn(null);
  }

  @Override
  public Executable serviceMethodThatShouldThrowNotFound() {
    var input = ProductDomain.builder().name("x").build();
    return () -> productService.update(999L, input);
  }
}
```

### 8.3 Mapper Tests (Pure Logic, No Mocks Needed)

```java
@ExtendWith(MockitoExtension.class)
class StoreDtoMapperTest {

  private final StoreDtoMapper mapper = new StoreDtoMapper();

  @Test
  void shouldMapDomainToDto() {
    var domain = StoreDomain.builder().id(1L).name("Toko Segar").build();

    var dto = mapper.toApiStore(domain);

    assertNotNull(dto);
    assertEquals(1L, dto.getId());
    assertEquals("Toko Segar", dto.getName());
  }

  @Test
  void shouldReturnNullWhenDomainIsNull() {
    assertNull(mapper.toApiStore(null));
  }
}
```

### 8.4 WebMvcTest for Controllers

```java
@WebMvcTest(StoreController.class)
class StoreControllerWebMvcTest {

  @MockBean private StoreWebAdapter storeWebAdapter;
  @Autowired private MockMvc mockMvc;

  @Test
  void shouldReturn200WhenStoreFound() throws Exception {
    when(storeWebAdapter.getStoreById(1L)).thenReturn(/* ... */);

    mockMvc.perform(get("/api/v1/stores/1"))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.data.name").value("Toko Segar"));
  }
}

@WebMvcTest are integration-lite: they load only the web layer with mocked adapters.
```

---

## 9. Running Tests in the Cycle

```bash
# Red phase — run to see it fail
mvn test -Dtest=ProductLookupServiceTest

# Green phase — run after minimal implementation
mvn test -Dtest=ProductLookupServiceTest

# Refactor phase — run entire module to catch regressions
mvn test

# Before commit — full gate
mvn verify
```

**Frequency**: Run the focused test every 2-5 minutes (every Red or Green step). Run the full suite before commit. The faster the feedback, the tighter the cycle.

---

## 10. Summary Checklist

- [ ] Test fails first (Red) — proves the test detects missing behavior
- [ ] Minimal code to pass (Green) — no speculative features
- [ ] Refactor with tests green — clean code is safe code
- [ ] One behavior per test — don't mix happy path and error path
- [ ] Verify interactions — `verify()` proves side effects happened
- [ ] Real domain objects — never mock models, use `.builder()`
- [ ] Fast and isolated — no Spring context in pure unit tests
- [ ] Run before commit — `mvn verify` must pass
