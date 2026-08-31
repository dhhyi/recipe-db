FROM node:lts-alpine AS builder
RUN npm i -g pnpm
WORKDIR /ws
COPY package.json pnpm-*.yaml /ws/
RUN pnpm i --frozen-lockfile
COPY . /ws/
RUN pnpm build

FROM busybox:latest
RUN adduser -D static
USER static
WORKDIR /home/static
COPY --from=builder /ws/dist/assets/index-*.css design/styles.css
RUN touch health
EXPOSE 3000
ENTRYPOINT ["busybox", "httpd", "-f", "-v", "-p", "3000"]
