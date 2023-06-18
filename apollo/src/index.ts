import { ApolloServer } from "@apollo/server";
import { startStandaloneServer } from "@apollo/server/standalone";
import { resolvers } from "./resolvers.js";
import { typeDefs } from "./typedefs.js";
import { context } from "./context.js";

if (!process.env.REST_ENDPOINT) {
  throw new Error("REST_ENDPOINT environment variable not set");
}

console.log("Using REST: " + process.env.REST_ENDPOINT);

const server = new ApolloServer({
  typeDefs,
  resolvers,
});

const { url } = await startStandaloneServer(server, {
  listen: { port: 4000 },
  context: async () => context,
});

console.log(`Apollo GraphQL started at: ${url}`);
