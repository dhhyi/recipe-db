FROM node:18-alpine as builder

RUN npm i -g pnpm
ENV NODE_ENV=production

WORKDIR /ws
COPY . /ws/
RUN pnpm i --frozen-lockfile --prod && pnpm build

FROM node:18-alpine

COPY --from=builder /ws/dist /dist

EXPOSE 4000

ENTRYPOINT ["node", "/dist/index.cjs"]
