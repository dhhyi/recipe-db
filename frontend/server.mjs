import { fileURLToPath } from "node:url";

import fastifyMiddie from "@fastify/middie";
import fastifyStatic from "@fastify/static";
import Fastify from "fastify";

import { handler as ssrHandler } from "./dist/server/entry.mjs";

function format(msg) {
  if (typeof msg === "string") {
    return msg;
  } else if (typeof msg === "object" && !!msg.method && !!msg.url) {
    if (msg.statusCode && msg.durationMs) {
      return `${msg.method} ${msg.url} ${msg.statusCode} ${msg.durationMs}ms`;
    }
    return `${msg.method} ${msg.url}`;
  }
  try {
    return JSON.stringify(msg);
  } catch (error) {
    return msg;
  }
}
function Logger(...args) {
  this.args = args;
}
Logger.prototype.info = function (msg) {
  console.log(format(msg));
};
Logger.prototype.error = function (msg) {
  console.log("ERROR", format(msg));
};
Logger.prototype.debug = function (msg) {
  console.log("DEBUG", format(msg));
};
Logger.prototype.fatal = function (msg) {
  console.log("FATAL", format(msg));
};
Logger.prototype.warn = function (msg) {
  console.log("WARN", format(msg));
};
Logger.prototype.trace = function (msg) {
  console.log("TRACE", format(msg));
};
Logger.prototype.child = function () {
  return new Logger();
};

const server = Fastify({
  logger: new Logger(),
  disableRequestLogging: true,
});

const now = () => Date.now();

server.addHook("onRequest", (req, reply, done) => {
  reply.startTime = now();
  req.log.info({ method: req.method, url: req.raw.url, id: req.id });
  done();
});

server.addHook("onResponse", (req, reply, done) => {
  req.log.info({
    url: req.raw.url,
    method: req.method,
    statusCode: reply.raw.statusCode,
    durationMs: now() - reply.startTime,
  });
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
