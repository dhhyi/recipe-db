# End-to-end tests

These tests reset shared test data and **must run sequentially**. Keep the existing single-worker Playwright configuration. Do not overlap test invocations, other integration suites, or interactive users against the same testing stack. Otherwise, unexpected behaviour is expected. There is no stack locking; the test configuration prints this warning whenever it is loaded.

Start the testing stack, then run tests through the devcontainer:

```sh
mise run dev-up
mise run --raw in-devcontainer e2e-test test
```

The degraded visual scenario temporarily ignores auxiliary backends through the testing-only GraphQL control. Fixtures clear ignored state before resetting/seeding data and in `finally` teardown. Setup or cleanup failures fail the test. After an interrupted run or failed cleanup, verify `setIgnoredServices(names: [])` succeeds before reusing the stack.

For browser history checks after a full-page link, wait for the destination URL to load and its main content to appear before calling `page.goBack()`. A completed click alone can precede the new document loading and race Chromium's navigation-history session.

See [testing-only degraded pages](../docs/browser-authentication.md#testing-only-degraded-pages) for the control, visual matrix, snapshot commands, and report workflow.
