import http from "http";

import { ApolloServer } from "@apollo/server";
import { expressMiddleware } from "@apollo/server/express4";
import { ApolloServerPluginDrainHttpServer } from "@apollo/server/plugin/drainHttpServer";
import bodyParser from "body-parser";
import cors from "cors";
import express from "express";

import { context, resolvers, typeDefs } from "./merge.js";

if (!process.env.REST_ENDPOINT) {
  throw new Error("REST_ENDPOINT environment variable not set");
}

console.log("Using REST: " + process.env.REST_ENDPOINT);

const TESTING = process.env.TESTING === "true";

const app = express();
const httpServer = http.createServer(app);

const server = new ApolloServer({
  typeDefs,
  resolvers,
  introspection: TESTING,
  plugins: [ApolloServerPluginDrainHttpServer({ httpServer })],
});

server
  .start()
  .then(async () => {
    app.use(
      "/graphql",
      cors<cors.CorsRequest>(),
      bodyParser.json({ limit: "2mb" }),
      expressMiddleware(server, {
        context: async () => context,
      }),
    );
    app.get("/health", (_, res) => {
      res.sendStatus(204);
    });

    await new Promise<void>((resolve) =>
      httpServer.listen({ port: 4000 }, resolve),
    ).then(() => {
      console.log(`Apollo GraphQL started`);
      if (TESTING) {
        console.log("TESTING MODE");
      }
    });
  })
  .catch((err) => {
    console.error(err);
    process.exit(1);
  });
