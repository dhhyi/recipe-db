# Tags REST tests

Integration tests for the tags service, implemented in [Groovy](https://groovy-lang.org/) with [Spock](https://spockframework.org/) and [REST Assured](https://rest-assured.io/).

## Test style

Spock provides test structure and assertions; REST Assured handles only HTTP requests and response access. See [`TagsSpec.groovy`](src/test/groovy/tags/TagsSpec.groovy).

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
