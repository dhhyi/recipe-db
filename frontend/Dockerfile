FROM node:18-alpine as builder
RUN npm i -g pnpm
WORKDIR /ws
COPY package.json pnpm-lock.yaml /ws/
RUN pnpm i --frozen-lockfile
COPY . /ws/
RUN pnpm build

FROM node:18-alpine as node_modules
WORKDIR /ws
COPY package.json pnpm-lock.yaml /ws/
RUN echo "node-linker=hoisted" > .npmrc
RUN npm i -g pnpm && pnpm i --frozen-lockfile --prod

FROM node:18-alpine
WORKDIR /app
COPY --from=builder /ws/dist /app
COPY --from=node_modules /ws/node_modules /app/node_modules
EXPOSE 3000
ENV NODE_ENV=production HOST=0.0.0.0 PORT=3000
ENTRYPOINT ["node", "./server/entry.mjs"]
