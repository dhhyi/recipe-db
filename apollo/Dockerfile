FROM node:lts-alpine as builder

RUN npm i -g pnpm

WORKDIR /ws
COPY . /ws/
RUN pnpm i --frozen-lockfile --prod && pnpm build

FROM node:lts-alpine

COPY --from=builder /ws/node_modules /node_modules
COPY --from=builder /ws/dist /dist
COPY --from=builder /ws/package.json /

EXPOSE 4000

ENTRYPOINT ["node", "/dist/index.js"]