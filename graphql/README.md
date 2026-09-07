# GraphQL Gateway

Combines all backend REST services into a single GraphQL API, implemented in Rust using
[async-graphql](https://async-graphql.github.io/async-graphql/en/index.html) and
[axum](https://github.com/tokio-rs/axum), built with [cargo-chef](https://github.com/LukeMathWalker/cargo-chef)
(mirroring the `recipes-edit` Dockerfile/devcontainer setup).

Query/mutation fields are merged per domain module (`recipes`, `ratings`, `images`, `inspirations`,
`image-inline`, `link-extract`, `traefik`) via `MergedObject`. Fields other domains contribute to
`Recipe`/`Link`/`ExtractedLink` are added via `ComplexObject` - since Rust only allows one
`impl ComplexObject` per type, those types are defined centrally (`src/recipe.rs`, `src/link.rs`)
with field bodies delegating to the owning domain module.

Running `cargo run -- print-schema` builds the `Schema` (without needing a running server or
`REST_ENDPOINT`) and prints its SDL to stdout; `.scripts/merge-graphql-schemas.js` shells out to this
via the devcontainer to produce `recipe-db.graphqls` for consumers.
