# Recipes Edit browser tests

This project tests browser behavior in the real Recipes Edit application with isolated GraphQL mocks. It uses the running development stack for editor and Design assets, but never seeds or resets application data. See the [testing guide](../docs/testing.md) for placement decisions.

With the development stack running, run from the repository root:

```sh
mise run --raw in-devcontainer recipe-edit-test pnpm integration
```

The shared integration runner also discovers this project's `integration` script:

```sh
mise run integration-tests -- --development recipe-edit-test
```

Other integration projects can change development data. Selecting this project alone does not reset or seed backend data.

Import `test` and `expect` from `fixtures.js`, not directly from Playwright. The fixture intercepts backend requests in each browser context, including popups, until that context is closed. Only editor and Design assets reach the stack; unexpected requests abort and fail the test. GraphQL operations and variables must match a declared mock.

Group tests by behavioral responsibility under `tests/`, starting with `tests/smoke/smoke.spec.js` and its adjacent `smoke.mocks.js`. Each test owns its mocks; do not reuse response data across tests or maintain a shared mock catalogue.

Declare each test's `graphqlMocks` and `identityHtml` in its adjacent `<test>.mocks.js` and activate them explicitly:

```js
test.use({ graphqlMocks: [graphqlMocks, { scope: "test" }], identityHtml });
```

The extra array wrapper distinguishes the array-valued fixture from Playwright's fixture-definition tuple. There are no shared default responses. Keep each scenario self-contained, including the new editor's `MyCapabilities` and `ServiceOnline` startup responses. The check command discovers all `tests/**/*.mocks.js` files and validates their exported `graphqlMocks` arrays.

For tests that leave the editor, supply a test-specific `returnDocument` to intercept the destination rather than let Browse make server-side GraphQL requests. Without an explicit response, identity requests and return navigation fail the test too. Do not use Playwright's API request context for backend requests; browser routing does not intercept those.

```sh
mise run --raw in-devcontainer recipe-edit-test check
```

`check` validates mock operations, variables and selected response data against the distributed schema and lists browser tests. Playwright runs isolated cases in parallel; the shared integration runner still executes projects sequentially.
