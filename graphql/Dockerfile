FROM rust:1-bookworm AS chef

RUN apt-get update && apt-get -y install --no-install-recommends musl-tools && apt-get clean && rm -rf /var/lib/apt/lists/*
RUN rustup target add x86_64-unknown-linux-musl
RUN cargo install cargo-chef --locked

WORKDIR /app

FROM chef AS planner
COPY Cargo.toml Cargo.lock ./
COPY src src
RUN cargo chef prepare --recipe-path recipe.json

FROM chef AS builder
COPY --from=planner /app/recipe.json recipe.json
RUN cargo chef cook --release --target x86_64-unknown-linux-musl --recipe-path recipe.json
COPY Cargo.toml Cargo.lock ./
COPY src src
RUN cargo build --release --target x86_64-unknown-linux-musl

FROM scratch

# scratch has no /tmp - async-graphql needs one to spool multipart file uploads to disk
COPY --from=builder --chmod=1777 /tmp /tmp
COPY --from=builder /app/target/x86_64-unknown-linux-musl/release/graphql /app/graphql

EXPOSE 4000
ENTRYPOINT ["/app/graphql"]
