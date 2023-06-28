import { mergeResolvers, mergeTypeDefs } from "@graphql-tools/merge";

import { type Resolvers } from "./generated/graphql.js";
import {
  ratingsTypeDefs,
  ratingsResolvers,
  ratingsContext,
  type RatingsContext,
} from "./ratings/index.js";
import {
  recipesTypeDefs,
  recipesResolvers,
  recipesContext,
  type RecipesContext,
} from "./recipes/index.js";

export const typeDefs = mergeTypeDefs([
  require("./typedefs.gql"),
  ratingsTypeDefs,
  recipesTypeDefs,
]);

export const context = {
  ...ratingsContext,
  ...recipesContext,
};

type Context = RatingsContext & RecipesContext;

export const resolvers: Resolvers<Context> = mergeResolvers([
  ratingsResolvers,
  recipesResolvers,
]);
