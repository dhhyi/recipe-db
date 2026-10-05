# GraphQL Gateway

Combines all backend REST services into a single GraphQL API, implemented in Rust using [async-graphql](https://async-graphql.github.io/async-graphql/en/index.html) and [axum](https://github.com/tokio-rs/axum), built with [cargo-chef](https://github.com/LukeMathWalker/cargo-chef) (mirroring the `recipes-edit` Dockerfile/devcontainer setup).

Query/mutation fields are merged per domain module (`recipes`, `ratings`, `images`, `inspirations`, `image-inline`, `link-extract`, `traefik`) via `MergedObject`. Fields other domains contribute to `Recipe`/`Link`/`ExtractedLink` are added via `ComplexObject` - since Rust only allows one `impl ComplexObject` per type, those types are defined centrally (`src/recipe.rs`, `src/link.rs`) with field bodies delegating to the owning domain module.

Running `mise run merge-graphql-schemas` from the repository root builds the GraphQL application image from the current source and runs its `print-schema` command to distribute the SDL to consuming projects. It prepares missing Compose configuration and the Docker network, reuses available Docker build caches, and never uses a devcontainer. Schema generation needs no running server or `REST_ENDPOINT`; build or generation failures leave existing schemas unchanged.
