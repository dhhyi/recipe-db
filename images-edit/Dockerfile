FROM node:lts-bookworm-slim@sha256:bc0a2afd3b74ce12222fc8bab99271e66257f021078f5f4a5d687a77d280c1d9 AS builder
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

FROM nginx:stable-alpine@sha256:0e52bd054126cdc040b1276c0af347aeb02a41b9cfe305d6094767ac30e97949
# COPY nginx.conf /etc/nginx/templates/default.conf.template
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html /usr/share/nginx/html
COPY --from=builder /app/elm.js /usr/share/nginx/html
