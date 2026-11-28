# Testing guide

This guide helps contributors and AI agents choose where behavior should be tested and keep script tests targeted. Use it when adding tests or reviewing existing coverage.

Related reading: [Project checks, tests, and formatting](../CONTRIBUTING.md#project-checks-tests-and-formatting).

## Contents

- [Frontend testing](#frontend-testing)
  - [Three testing buckets](#three-testing-buckets)
  - [Choosing where a test belongs](#choosing-where-a-test-belongs)
  - [Assertion boundaries](#assertion-boundaries)
  - [Screenshots and explicit assertions](#screenshots-and-explicit-assertions)
  - [Avoiding duplicate coverage](#avoiding-duplicate-coverage)
  - [Checking and updating mocks](#checking-and-updating-mocks)
  - [Revisiting existing tests](#revisiting-existing-tests)
- [Script testing](#script-testing)

## Frontend testing

### Three testing buckets

Frontend coverage has three responsibilities:

| Bucket | Responsibility |
| --- | --- |
| **Unit tests** | Verify deterministic logic, state transitions, transformations, payloads and derived messages without a browser. |
| **Mocked browser tests** | Verify browser-dependent behavior using controlled backend responses, without changing backend data. |
| **Real-stack end-to-end tests** | Verify representative cross-application journeys, actual persistence and real integration boundaries. |

Choose the lowest boundary that reliably protects the intended behavior. Do not repeat the same behavioral coverage across buckets.

The bucket describes what a test verifies, not merely how its environment starts. A mocked browser suite may use an application served by the running stack while intercepting its backend requests.

Keep coverage with the application or component that owns the behavior. Shared-component internals belong with the shared component; application wiring belongs with the application.

### Choosing where a test belongs

#### What behavior must the test protect?

Describe the observable contract and the regression the test should catch before choosing a tool or fixture.

Classify the behavior, not the existing test file. A test containing several responsibilities may need splitting.

Organize test files around cohesive behavioral responsibilities, with names that make their purpose clear. When adding or relocating coverage, review whether it belongs in the existing file or a separate focused file. Do not collect unrelated scenarios in one large suite merely because they exercise the same application. A representative E2E journey may span several behaviors when their integration is the contract being tested.

#### Does verification require a browser?

If the behavior can be verified reliably through deterministic inputs, outputs or state transitions, use unit tests.

Examples include:

- Comparing edited state with a saved baseline.
- Constructing a save payload.
- Selecting an error message from a response.

Use browser coverage when the contract depends on real rendering, layout, focus, user interaction, animation or native browser behavior.

A browser test is not justified solely because the result eventually appears on screen. Conversely, testing state alone does not verify that browser controls are wired correctly.

#### Does verification require real backend interaction?

If controlled responses can faithfully verify the browser behavior, use mocked browser tests.

Examples include:

- Controls remaining disabled while a save is pending.
- Error feedback and retry interaction.
- Focus restoration and unsaved-change prompts.

Mock all relevant backend requests. Unexpected requests must fail the test rather than reach a real backend. Mocks and mutable test state must be isolated between tests.

Mocked success verifies the frontend's response handling; it does not prove that data was persisted.

#### When does verification require real-stack E2E?

Use real-stack E2E when the contract depends on real integration, such as:

- Creating or editing a recipe and observing persisted changes in another application.
- Navigating between applications and verifying their integration.
- Representative assembled-page rendering that protects a distinct integration risk.

Real-stack E2E is also appropriate when faithful mocking would require disproportionately complex or fragile fixtures.

Keep E2E journeys focused. They should not repeat exhaustive lower-level permutations.

### Assertion boundaries

Assert the contract exposed at the chosen boundary, rather than incidental implementation details.

#### Unit tests

- Assert logic, state transitions, outputs and payloads.
- Avoid incidental internal structure that is not part of the tested contract.

#### Browser tests

These rules apply to both mocked browser tests and real-stack E2E tests:

- Assert observable outcomes, not CSS classes or private application state. Tailwind utility classes are implementation details, not proof of visibility, sizing or interaction behavior.
- Assert browser-calculated geometry when it verifies a meaningful requirement, such as no horizontal overflow or a minimum interactive target size. Avoid incidental pixel values that are not part of the contract.

Within those boundaries:

- **Mocked browser tests** assert rendered behavior, accessibility, focus, interaction and frontend requests to mocked backends.
- **Real-stack E2E tests** remain black-box: assert what a user or external consumer can observe, including cross-application navigation and real persistence. Avoid exhaustive lower-level cases.

E2E fixtures disable View Transitions by default, and the Playwright configuration requests reduced motion. Tests specifically covering View Transitions opt in with `test.extend({ viewTransitions: true })`; tests covering CSS motion also select `reducedMotion: "no-preference"`.

### Screenshots and explicit assertions

Screenshots are an assertion method, not another testing bucket. Both mocked browser tests and real-stack E2E tests may use them.

#### When to use screenshots

Use screenshot comparisons when the contract is approved appearance, including spacing, typography, colors and composition.

#### When to use explicit assertions

Use explicit assertions when the contract is a specific behavioral or layout requirement, including visibility, focus, interaction or required size constraints.

These assertions protect requirements independently of the screenshot baseline. Accepting a changed screenshot must not make a violated requirement pass.

#### When to use both

Combine screenshots and explicit assertions when they protect distinct contracts: approved appearance and specific requirements within that appearance. Do not add assertions for every CSS property or pixel already represented in a screenshot.

Follow the [screenshot baseline rules](../CONTRIBUTING.md#e2e-screenshot-baselines). Review baseline changes against the intended appearance and requirements rather than accepting them solely because the implementation changed.

### Avoiding duplicate coverage

Give each behavioral contract a clear testing home.

Higher-level tests will naturally exercise lower-level functionality. That is acceptable when they verify a distinct boundary. Repeating the same edge cases and assertions at several levels is not.

Keep exhaustive logic cases in unit tests, browser-specific cases in mocked browser tests, and representative real integration journeys in E2E.

### Checking and updating mocks

#### Checking GraphQL mocks

Declare `graphqlSchema` in the mocked browser project's metadata. Its `check` script must use a GraphQL parser and schema-aware validator to validate mock queries and mutations against the distributed GraphQL schema. Mock response data must also be validated against the operation's selected fields and their schema types. Checking JSON syntax or matching field names alone is not sufficient. See the [schema distribution](../CONTRIBUTING.md#generated-source-synchronization) and [project script contract](../CONTRIBUTING.md#project-checks-tests-and-formatting).

A GraphQL response can contain both data and errors. Compose mocks to reflect real backend responses, including scenarios where some data is available despite an error.

Write mock responses for the scenario being tested. There is no need to record real responses or run every mocked scenario again against a real backend. Existing API and service contract tests check the real backend.

#### Updating mocks when the backend changes

Passing the schema check does not prove that a mock matches the backend's behavior. For example, a mock can use the right field types but return an error code that the backend no longer uses.

When backend behavior changes, check the mocks for that behavior and update them too. This includes changed error codes, returned fields and which data remains available after an error.

### Revisiting existing tests

Revisit a test's placement when the behavior or its owner changes. For example:

- Behavior moves from an application into a shared component.
- Logic is extracted into a helper with unit coverage.
- A test grows to cover several unrelated responsibilities.
- New coverage makes an existing test redundant.

Apply the same placement questions as for a new test. Its current location is not a reason to keep it there.

Before moving or removing coverage, identify the behavior and boundaries it protects. A test may be removed without replacement if its value does not justify its maintenance cost and the remaining risk is acceptable. Otherwise, confirm that existing coverage or a tested replacement still protects those behaviors and boundaries. Keep higher-level coverage when it verifies a distinct integration contract, even if the underlying logic now has unit tests.

## Script testing

Declare ignored generated files needed by a suite as exact paths in [the script input manifest](../.scripts/tests/groups.yaml). They must exist before BUILD generation; glob patterns only discover non-ignored files.

Each Bats suite must complete in at most three minutes so it remains useful for targeted testing. When adding, changing, or relocating script tests, review each affected suite as a whole; split or improve a suite that exceeds the limit without losing its behavioral coverage.

Measure each affected suite's wall-clock time with a complete, uncached run using the normal configuration, for example:

```sh
/usr/bin/time -p mise run --raw bazel test --nocache_test_results --test_output=errors //:test_scripts_suite_production-k3d-backup
```

Use the reported `real` time, not a cached Bazel result or a subset of tests. Record the command, elapsed time, result, and skipped or opt-in tests in the validation evidence. A failed run or missing timing does not establish compliance. Report over-limit or unverified suites as unresolved; do not claim the limit is met.
