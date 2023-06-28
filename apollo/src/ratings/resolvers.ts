import type {
  MutationResolvers,
  QueryResolvers,
  RecipeResolvers,
  Resolvers,
} from "../generated/graphql.js";

import type { RatingsContext } from "./context.js";

const Query: QueryResolvers<RatingsContext> = {
  rating: async (_source, { id }, { ratingsAPI }) => {
    return await ratingsAPI.getRating(id);
  },
};

const Mutation: MutationResolvers<RatingsContext> = {
  deleteRatingsForTesting: async (_source, _args, { ratingsAPI }) => {
    return await ratingsAPI.deleteRatingsForTesting();
  },

  rate: async (_source, { id, rating, login }, { ratingsAPI }) => {
    return await ratingsAPI.addRating(id, rating, login);
  },
};

const Recipe: RecipeResolvers<RatingsContext> = {
  rating: async (source, _args, { ratingsAPI }) => {
    return await ratingsAPI.getRating(source.id);
  },
};

export const ratingsResolvers: Resolvers<RatingsContext> = {
  Query,
  Mutation,
  Recipe,
};
