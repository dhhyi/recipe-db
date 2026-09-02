FROM node:lts-alpine AS builder
RUN npm i -g pnpm
WORKDIR /ws
COPY package.json pnpm-*.yaml /ws/
RUN pnpm i --frozen-lockfile
COPY . /ws/
RUN pnpm build

FROM nginx:stable-alpine-perl
RUN sed -i '1i load_module modules/ngx_http_perl_module.so;' /etc/nginx/nginx.conf
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=builder /ws/dist /usr/share/nginx/html
