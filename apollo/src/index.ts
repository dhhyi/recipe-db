import { ApolloServer } from "@apollo/server";
import { startStandaloneServer } from "@apollo/server/standalone";
import { resolvers } from "./resolvers.js";
import { context } from "./context.js";

if (!process.env.REST_ENDPOINT) {
  throw new Error("REST_ENDPOINT environment variable not set");
}

console.log("Using REST: " + process.env.REST_ENDPOINT);

const typeDefs: string = require("./typedefs.gql");

const server = new ApolloServer({
  typeDefs,
  resolvers,
});

startStandaloneServer(server, {
  listen: { port: 4000 },
  context: async () => context,
}).then(({ url }) => {
  console.log(`Apollo GraphQL started at: ${url}`);
});
