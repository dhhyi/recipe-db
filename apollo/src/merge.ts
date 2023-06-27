import { mergeResolvers, mergeTypeDefs } from "@graphql-tools/merge";

import { Resolvers } from "./generated/graphql.js";

import {
  ratingsTypeDefs,
  ratingsResolvers,
  ratingsContext,
  RatingsContext,
} from "./ratings/index.js";
import {
  recipesTypeDefs,
  recipesResolvers,
  recipesContext,
  RecipesContext,
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
