# Recipe Adding and Editing

Implemented as a client-side ClojureScript application with Reagent, re-frame, and re-graph. An
nginx container serves the compiled shadow-cljs bundle and falls back to `index.html` for the
`/edit/new` and `/edit/:id` routes. The browser sends queries and mutations directly to `/graphql`.

`operations.graphql` remains the source of GraphQL operations. A Clojure macro validates those
operations against `recipe-db.graphqls` with graphql-java during compilation, then embeds the named
operations in the browser bundle.

Run project commands through the devcontainer from the repository root:

```sh
pnpm in-devcontainer recipes-edit pnpm watch
pnpm in-devcontainer recipes-edit pnpm test
pnpm in-devcontainer recipes-edit precommit
```
