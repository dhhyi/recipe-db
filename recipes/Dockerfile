FROM elixir:1.18.4-otp-27-slim@sha256:09b37446f1b24a280890c4b294eec6a53ba2501a2289959b483d849035e1053c AS builder

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

FROM debian:bookworm-slim@sha256:3783cc01769c7b2b1b83a5c5ad96c815348e28ed7da68e2e3687004faa906251 AS runner

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates libstdc++6 openssl \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=builder /app/_build/prod/rel/recipes ./

ENV HOME=/app \
  LANG=C.UTF-8 \
  LC_ALL=C.UTF-8

EXPOSE 5000

CMD ["/app/bin/recipes", "start"]
