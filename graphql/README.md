# GraphQL Gateway

Combines all backend REST services into a single GraphQL API, implemented in Rust using [async-graphql](https://async-graphql.github.io/async-graphql/en/index.html) and [axum](https://github.com/tokio-rs/axum), built with [cargo-chef](https://github.com/LukeMathWalker/cargo-chef) (mirroring the `recipes-edit` Dockerfile/devcontainer setup).

Query/mutation fields are merged per domain module (`recipes`, `ratings`, `images`, `inspirations`, `image-inline`, `link-extract`, `traefik`) via `MergedObject`. Fields other domains contribute to `Recipe`/`Link`/`ExtractedLink` are added via `ComplexObject` - since Rust only allows one `impl ComplexObject` per type, those types are defined centrally (`src/recipe.rs`, `src/link.rs`) with field bodies delegating to the owning domain module.

Running `mise run merge-graphql-schemas` from the repository root ensures development Compose configuration, refreshes the cached canonical SDL at `.generated/graphql/recipe-db.graphqls` when GraphQL build inputs change, then repairs metadata-declared consumer copies. It reuses available Docker build caches and never uses a devcontainer. Schema generation needs no account map, auth provider, running server, or `REST_ENDPOINT`; build or generation failures leave existing schemas unchanged.

The public Mise task owns prerequisite ordering and freshness checks. The underlying `.scripts/merge-graphql-schemas.sh` only distributes an already cached SDL; invoking that script directly does not run Mise dependencies or build the schema. Use `mise run --force merge-graphql-schemas` to refresh against external Docker or registry changes that are not local file inputs.
