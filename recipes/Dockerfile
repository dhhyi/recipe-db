FROM hexpm/elixir:1.18.5-erlang-27.3.4.19-debian-trixie-20261027-slim@sha256:37e5d9e8cfb102bd3e7282362b64babd326e86bdea850470aa83367b29690955 AS builder

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

FROM debian:trixie-slim@sha256:f6b08b09a05725f9431502d3b5714f5c4576e82c1a84fa1debe0c24a7e0c3ec4 AS runner

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates libstdc++6 openssl \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=builder /app/_build/prod/rel/recipes ./

ENV HOME=/app \
  LANG=C.UTF-8 \
  LC_ALL=C.UTF-8

EXPOSE 5000

CMD ["/bin/sh", "-c", "APP_MODE=\"${MODE-production}\" exec /app/bin/recipes start"]
