FROM node:lts-bookworm AS builder
RUN npm i -g pnpm@11
WORKDIR /app
COPY package.json pnpm-*.yaml /app/
RUN pnpm i --frozen-lockfile
COPY . /app/
RUN pnpm codegen --skip-elm-format
RUN pnpm build --optimize

FROM nginx:stable-alpine
# COPY nginx.conf /etc/nginx/templates/default.conf.template
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html /usr/share/nginx/html
COPY --from=builder /app/elm.js /usr/share/nginx/html
