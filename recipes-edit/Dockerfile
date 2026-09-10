FROM node:lts-bookworm AS node

FROM clojure:temurin-21-tools-deps-bookworm-slim AS builder
COPY --from=node /usr/local /usr/local
RUN npm install --global pnpm@11

WORKDIR /app
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
RUN pnpm install --frozen-lockfile
COPY deps.edn shadow-cljs.edn operations.graphql recipe-db.graphqls ./
COPY src src
RUN pnpm build

FROM nginx:stable-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html /usr/share/nginx/html/index.html
COPY --from=builder /app/public/js /usr/share/nginx/html/js
