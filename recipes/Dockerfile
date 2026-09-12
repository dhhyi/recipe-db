FROM elixir:1.18.4-otp-27-slim AS builder

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

FROM debian:bookworm-slim AS runner

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
