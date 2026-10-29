# Tags REST tests

Integration tests for the tags service, implemented in [Groovy](https://groovy-lang.org/) with [Spock](https://spockframework.org/) and [REST Assured](https://rest-assured.io/).

## Suite overview

| Spec | Coverage |
| --- | --- |
| [`TagInventorySpec`](src/test/groovy/tags/TagInventorySpec.groovy) | Inventory shape and ordering, categories, normalization, collisions, display-name validation, deletion |
| [`TagAssignmentsSpec`](src/test/groovy/tags/TagAssignmentsSpec.groovy) | Assignment lifecycle, encoded recipe IDs, atomic bulk changes, recipe-edit independence |
| [`TagHttpContractSpec`](src/test/groovy/tags/TagHttpContractSpec.groovy) | Malformed payloads, media types, unknown routes, unsupported methods |
| [`TagRuntimeSpec`](src/test/groovy/tags/TagRuntimeSpec.groovy) | Health, testing resets, production reset protection |
| [`TagConcurrencySpec`](src/test/groovy/tags/TagConcurrencySpec.groovy) | Concurrent creation and assignment/deletion races |

The abstract [`TagsApiSpec`](src/test/groovy/tags/TagsApiSpec.groovy) shares endpoint setup, health polling, the per-test reset, and small HTTP, tag-creation, and URL-encoding helpers. Topic-specific fixtures and assertions stay in their own specs.

The specs share one isolated tags database and reset it before each test. [`SpockConfig.groovy`](src/test/resources/SpockConfig.groovy) disables parallel execution; keep Gradle's single-test-worker default as well. Concurrency tests create their own concurrent requests within a single test.

## Test style

Spock provides test structure and assertions; REST Assured handles only HTTP requests and response access.

- Use Spock's `given:`, `when:`, and `then:` blocks for setup, actions, and expectations. Use `expect:` for simple action-and-result checks.
- Send requests through the small `http` helper, which returns a REST Assured `Response`. Keep transport details in the helper, not assertions.
- Write native Spock conditions for status codes, headers, and JSON values. Avoid REST Assured's `given().then()` validation chains and Hamcrest matchers: they introduce a second BDD vocabulary and assertion style.
- Use explicit `assert` in setup, cleanup, helper methods, and nested closures or control flow; do not rely on Spock's implicit top-level conditions there.
- Use `where:` tables and `@Unroll` for related input cases, so each case gets its own result and failures remain easy to identify.

For example, using the existing `create` helper:

```groovy
def 'same identity key in different categories creates independent tags'() {
    when:
    def first = create('cuisine', 'Soup')
    def second = create('course', 'Soup')

    then:
    first.statusCode() == 201
    second.statusCode() == 201
    first.jsonPath().getString('id') == 'cuisine-soup'
    second.jsonPath().getString('id') == 'course-soup'
}
```

Keep assertions visible in the feature test rather than hiding them in generic validation helpers. Spock's condition diagnostics show the actual values when an expectation fails.
