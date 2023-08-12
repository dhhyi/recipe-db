import { fileURLToPath } from "node:url";

import fastifyMiddie from "@fastify/middie";
import fastifyStatic from "@fastify/static";
import Fastify from "fastify";

import { handler as ssrHandler } from "./dist/server/entry.mjs";

const server = Fastify({
  logger: true,
  disableRequestLogging: true,
});

const now = () => Date.now();

server.addHook("onRequest", (req, reply, done) => {
  reply.startTime = now();
  req.log.info({ url: req.raw.url, id: req.id }, "received request");
  done();
});

server.addHook("onResponse", (req, reply, done) => {
  req.log.info(
    {
      url: req.raw.url, // add url to response as well for simple correlating
      statusCode: reply.raw.statusCode,
      durationMs: now() - reply.startTime, // recreate duration in ms - use process.hrtime() - https://nodejs.org/api/process.html#process_process_hrtime_bigint for most accuracy
    },
    "request completed",
  );
  done();
});

await server
  .register(fastifyStatic, {
    root: fileURLToPath(new URL("./dist/client", import.meta.url)),
  })
  .register(fastifyMiddie);
server.use(ssrHandler);
server.get("/health", async (_, res) => {
  res.status(204).send();
});

const port = process.env.PORT || 3000;
const host = process.env.HOST || "0.0.0.0";

server.listen(
  {
    port,
    host,
  },
  (err) => {
    if (err) {
      server.log.error(err);
      process.exit(1);
    }
  },
);
