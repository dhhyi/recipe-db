FROM rust:1-bookworm AS chef

RUN apt-get update && apt-get -y install --no-install-recommends musl-tools && apt-get clean && rm -rf /var/lib/apt/lists/*
RUN rustup target add wasm32-unknown-unknown x86_64-unknown-linux-musl
RUN cargo install cargo-chef cargo-leptos --locked

WORKDIR /app

FROM chef AS planner
COPY Cargo.toml Cargo.lock ./
COPY src src
COPY style style
RUN cargo chef prepare --recipe-path recipe.json

FROM chef AS builder
COPY --from=planner /app/recipe.json recipe.json
# pre-bake dependency compilation for both cargo-leptos targets, cached independently of src changes
RUN cargo chef cook --release --target x86_64-unknown-linux-musl --no-default-features --features ssr --recipe-path recipe.json
RUN cargo chef cook --release --target wasm32-unknown-unknown --no-default-features --features hydrate --recipe-path recipe.json
COPY Cargo.toml Cargo.lock build.rs recipe-db.graphqls operations.graphql ./
COPY src src
COPY style style
RUN cargo leptos build --release

FROM scratch

WORKDIR /app
COPY --from=builder /app/target/x86_64-unknown-linux-musl/release/recipes-edit /app/
COPY --from=builder /app/target/site /app/site

ENV LEPTOS_SITE_ROOT=/app/site
ENV LEPTOS_SITE_ADDR=0.0.0.0:3000
EXPOSE 3000
ENTRYPOINT ["/app/recipes-edit"]
