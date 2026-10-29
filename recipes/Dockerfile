FROM elixir:1.18-otp-27-slim@sha256:4d24a682c9063a6961e44a95ada95d4803d856a53a52b26568f0cc3ed62e9386 AS builder

ENV LANG=C.UTF-8 \
  LC_ALL=C.UTF-8 \
  MIX_ENV=prod

RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential ca-certificates git \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod && mix deps.compile

COPY lib ./lib
RUN mix compile && mix release

FROM debian:bookworm-slim@sha256:99c0b25c46d0214d5a2091092e7908907dcaecd6a962cde0ac700acee222b6f3 AS runner

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates libstdc++6 openssl \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=builder /app/_build/prod/rel/recipes ./

ENV HOME=/app \
  LANG=C.UTF-8 \
  LC_ALL=C.UTF-8

EXPOSE 5000

CMD ["/bin/sh", "-c", "RECIPES_RUNTIME_MODE=\"${MODE-production}\" exec /app/bin/recipes start"]
