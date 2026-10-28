FROM node:lts-bookworm-slim@sha256:be8204d4bd327363357f532187b752ff62759c31bedf98e9e18fc08c9cbd605c AS builder
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates \
  && rm -rf /var/lib/apt/lists/*
RUN npm i -g pnpm@12.6.0
WORKDIR /app
COPY package.json pnpm-*.yaml /app/
RUN pnpm i --frozen-lockfile
COPY . /app/
RUN pnpm codegen --skip-elm-format
RUN pnpm build --optimize

FROM nginx:stable-alpine@sha256:47928bf67eb62a1863cb08d9ecb52d3e704304ba614eaee17884204677702951
# COPY nginx.conf /etc/nginx/templates/default.conf.template
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html /usr/share/nginx/html
COPY --from=builder /app/elm.js /usr/share/nginx/html
