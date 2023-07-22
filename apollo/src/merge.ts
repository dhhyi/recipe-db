import { mergeResolvers, mergeTypeDefs } from "@graphql-tools/merge";

import { type Resolvers } from "./generated/graphql.js";
import * as imageInline from "./image-inline/index.js";
import * as inspirations from "./inspirations/index.js";
import * as linkExtract from "./link-extract/index.js";
import * as ratings from "./ratings/index.js";
import * as recipes from "./recipes/index.js";

export const typeDefs = mergeTypeDefs([
  require("./typedefs.gql"),
  imageInline.typeDefs,
  inspirations.typeDefs,
  linkExtract.typeDefs,
  ratings.typeDefs,
  recipes.typeDefs,
]);

export const context = {
  ...imageInline.context,
  ...inspirations.context,
  ...linkExtract.context,
  ...ratings.context,
  ...recipes.context,
};

export type Context = typeof context;

export const resolvers: Resolvers<Context> = mergeResolvers([
  imageInline.resolvers,
  inspirations.resolvers,
  linkExtract.resolvers,
  ratings.resolvers,
  recipes.resolvers,
]);
