# Recipes

Recipe storage service implemented in [Elixir](https://elixir-lang.org/) with
[Plug](https://hexdocs.pm/plug/), [Bandit](https://hexdocs.pm/bandit/), and
[SQLite](https://sqlite.org/) through [Exqlite](https://hexdocs.pm/exqlite/).

Recipes are stored as schemaless JSON documents and identified by UUID v4 IDs. The service exposes
the following endpoints on port 5000:

- `GET /health`
- `GET /recipes`
- `POST /recipes`
- `GET /recipes/:id`
- `PATCH /recipes/:id`
- `DELETE /recipes/:id`

Create requests use `application/json`. Updates implement JSON Merge Patch (RFC 7396) and require
`application/merge-patch+json`. Errors use Problem Details (RFC 9457).

The database defaults to `db/recipes.sqlite3`. Set `DATA_LOCATION` to change its directory. When
`TESTING=true`, `DELETE /recipes` clears all recipes for integration tests.

Run unit tests with:

```sh
pnpm in-devcontainer recipes test
```

Integration testing in [`recipes-test`](../recipes-test) uses
[Venom](https://github.com/ovh/venom).

Still open: versioning of recipe data and rollback of edits.
