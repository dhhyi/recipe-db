import type {
  MutationResolvers,
  QueryResolvers,
  RecipeResolvers,
  Resolvers,
} from "../generated/graphql.js";
import type { RatingsContext } from "./context.js";

const Query: QueryResolvers<RatingsContext> = {
  rating: async (_source, { id }, { ratingsAPI }) => {
    return ratingsAPI.getRating(id);
  },
};

const Mutation: MutationResolvers<RatingsContext> = {
  deleteRatingsForTesting: async (_source, _args, { ratingsAPI }) => {
    return ratingsAPI.deleteRatingsForTesting();
  },

  rate: async (_source, { id, rating, login }, { ratingsAPI }) => {
    return ratingsAPI.addRating(id, rating, login);
  },
};

const Recipe: RecipeResolvers<RatingsContext> = {
  rating: async (source, _args, { ratingsAPI }) => {
    return ratingsAPI.getRating(source.id);
  },
};

export const ratingsResolvers: Resolvers<RatingsContext> = {
  Query,
  Mutation,
  Recipe,
};
