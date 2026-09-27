FROM node:lts-bookworm-slim@sha256:0e0ff40c39bc087845bfb27465a0df4ea419520094bc35842ff83dd8cbe6f9b6 AS builder
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

FROM nginx:stable-alpine@sha256:0985e772fb9f729e6fa0980da05fca5d9c468e870eed43071545afa9d2e27d94
# COPY nginx.conf /etc/nginx/templates/default.conf.template
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html /usr/share/nginx/html
COPY --from=builder /app/elm.js /usr/share/nginx/html
