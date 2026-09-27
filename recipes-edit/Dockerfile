FROM node:lts-bookworm-slim@sha256:0e0ff40c39bc087845bfb27465a0df4ea419520094bc35842ff83dd8cbe6f9b6 AS node

FROM clojure:temurin-21-tools-deps-bookworm-slim@sha256:1acb1f4f441b14b0cf321afcb838f52ccc55eb76b3bab0746aa83a9aed27b5d5 AS builder
COPY --from=node /usr/local /usr/local
RUN npm install --global pnpm@12.6.0

WORKDIR /app
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
RUN pnpm install --frozen-lockfile
COPY deps.edn shadow-cljs.edn operations.graphql recipe-db.graphqls ./
COPY src src
RUN pnpm build

FROM nginx:stable-alpine@sha256:0985e772fb9f729e6fa0980da05fca5d9c468e870eed43071545afa9d2e27d94
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html /usr/share/nginx/html/index.html
COPY --from=builder /app/public/js /usr/share/nginx/html/js
