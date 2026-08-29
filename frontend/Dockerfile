FROM node:lts-alpine AS builder
RUN npm i -g pnpm
WORKDIR /ws
COPY package.json pnpm-*.yaml /ws/
RUN pnpm i --frozen-lockfile
COPY . /ws/
RUN npm run codegen && pnpm build

FROM node:lts-alpine AS node_modules
WORKDIR /ws
COPY package.json pnpm-*.yaml /ws/
RUN echo "node-linker=hoisted" > .npmrc
RUN npm i -g pnpm && pnpm i --frozen-lockfile --prod

FROM node:lts-alpine
RUN apk add --no-cache tini
WORKDIR /app
COPY --from=builder /ws/dist /app/dist/
COPY --from=node_modules /ws/node_modules /app/node_modules
COPY server.mjs /app/server.mjs
EXPOSE 3000
ENV NODE_ENV=production HOST=0.0.0.0 PORT=3000
ENTRYPOINT [ "tini", "--" ]
CMD [ "node", "./server.mjs" ]
