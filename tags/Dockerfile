FROM debian:bookworm-slim@sha256:99c0b25c46d0214d5a2091092e7908907dcaecd6a962cde0ac700acee222b6f3 AS builder

ENV OPAMYES=1

RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential ca-certificates curl libev-dev libgmp-dev libsqlite3-dev libssl-dev opam pkg-config \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN opam init --disable-sandboxing --bare --yes \
  && opam switch create 5.3.0 --jobs=2 --yes

COPY tags.opam dune-project ./
RUN opam install --switch=5.3.0 --deps-only --yes ./tags.opam

COPY src ./src
COPY bin ./bin
COPY test ./test
RUN opam exec --switch=5.3.0 -- dune build --profile release ./bin/main.exe \
  && cp _build/default/bin/main.exe /app/tags

FROM debian:bookworm-slim@sha256:99c0b25c46d0214d5a2091092e7908907dcaecd6a962cde0ac700acee222b6f3 AS runner

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates libev4 libgmp10 libsqlite3-0 libssl3 \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=builder /app/tags ./tags

ENV DATA_LOCATION=/data \
  MODE=production

EXPOSE 8900

CMD ["/app/tags"]
