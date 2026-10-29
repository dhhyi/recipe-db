FROM node:lts-bookworm-slim@sha256:bc0a2afd3b74ce12222fc8bab99271e66257f021078f5f4a5d687a77d280c1d9 AS node

FROM clojure:temurin-21-tools-deps-bookworm-slim@sha256:e412035074cfebebe388bddc40c0c0c83817bf04a765f9a407491b678d2cbb47 AS builder
COPY --from=node /usr/local /usr/local
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
