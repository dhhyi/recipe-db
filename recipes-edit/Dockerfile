FROM node:lts-trixie-slim@sha256:e4db4c914bf8ad241bd24804fc25d272d89bad97e68cdc8a1414862790a02c39 AS node

FROM clojure:temurin-21-tools-deps-trixie-slim@sha256:46a6325db658150fb2601756cfca7489fb35ae0292d38d65dc76a781a678f782 AS builder
COPY --from=node /usr/local /usr/local
RUN apt-get update && apt-get install -y --no-install-recommends libatomic1 && rm -rf /var/lib/apt/lists/*
RUN npm install --global pnpm@12.6.0

WORKDIR /app
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
RUN pnpm install --frozen-lockfile
COPY deps.edn shadow-cljs.edn operations.graphql recipe-db.graphqls ./
COPY src src
RUN pnpm build

FROM nginx:stable-alpine@sha256:0e52bd054126cdc040b1276c0af347aeb02a41b9cfe305d6094767ac30e97949
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html /usr/share/nginx/html/index.html
COPY --from=builder /app/public/js /usr/share/nginx/html/js
