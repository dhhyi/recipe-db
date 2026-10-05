FROM rust:1-slim-bookworm@sha256:452176c0cefca88c0b3184ce85a4eb03e3d4fa05d2afb5366abcba853221019e AS chef

RUN apt-get update && apt-get -y install --no-install-recommends musl-tools && apt-get clean && rm -rf /var/lib/apt/lists/*
RUN rust_target=$(rustc -vV | sed -n 's/^host: \(.*\)-unknown-linux-gnu$/\1-unknown-linux-musl/p') \
  && test -n "$rust_target" \
  && printf '%s\n' "$rust_target" > /rust-target \
  && rustup target add "$rust_target"
RUN cargo install cargo-chef --locked

WORKDIR /app

FROM chef AS planner
COPY Cargo.toml Cargo.lock ./
COPY src src
RUN cargo chef prepare --recipe-path recipe.json

FROM chef AS builder
COPY --from=planner /app/recipe.json recipe.json
RUN rust_target=$(cat /rust-target) \
  && cargo chef cook --release --target "$rust_target" --recipe-path recipe.json
COPY Cargo.toml Cargo.lock ./
COPY src src
RUN rust_target=$(cat /rust-target) \
  && cargo build --release --target "$rust_target" \
  && mkdir -p /app/output \
  && cp "target/$rust_target/release/graphql" /app/output/graphql

FROM scratch

# scratch has no /tmp - async-graphql needs one to spool multipart file uploads to disk
COPY --from=builder --chmod=1777 /tmp /tmp
COPY --from=builder /app/output/graphql /app/graphql

EXPOSE 4000
ENTRYPOINT ["/app/graphql"]
