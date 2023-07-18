import { mergeResolvers, mergeTypeDefs } from "@graphql-tools/merge";

import { type Resolvers } from "./generated/graphql.js";
import { inspirationsContext } from "./inspirations/context.js";
import {
  inspirationsResolvers,
  inspirationsTypeDefs,
} from "./inspirations/index.js";
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
  inspirationsTypeDefs,
  ratingsTypeDefs,
  recipesTypeDefs,
]);

export const context = {
  ...inspirationsContext,
  ...ratingsContext,
  ...recipesContext,
};

type Context = RatingsContext & RecipesContext;

export const resolvers: Resolvers<Context> = mergeResolvers([
  inspirationsResolvers,
  ratingsResolvers,
  recipesResolvers,
]);
