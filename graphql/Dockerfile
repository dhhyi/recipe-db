FROM node:lts-alpine AS builder

RUN npm i -g pnpm
ENV NODE_ENV=production

WORKDIR /ws
COPY package.json pnpm-*.yaml /ws/
RUN pnpm i --frozen-lockfile --prod
COPY . /ws/
RUN pnpm build

FROM node:18-alpine

COPY --from=builder /ws/dist /app

EXPOSE 4000

ENTRYPOINT ["node", "/app/index.cjs"]
