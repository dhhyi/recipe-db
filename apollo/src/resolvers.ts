import { Context } from "./context.js";
import {
  MutationResolvers,
  QueryResolvers,
  RecipeResolvers,
  Resolvers,
} from "./graphql.js";

const Query: QueryResolvers<Context> = {
  recipes: async (_source, _args, { recipesAPI }) => {
    return recipesAPI.getRecipes();
  },
  recipe: async (_source, { id }, { recipesAPI }) => {
    return recipesAPI.getRecipe(id);
  },

  rating: async (_source, { id }, { ratingsAPI }) => {
    return ratingsAPI.getRating(id);
  },
};

const Mutation: MutationResolvers<Context> = {
  deleteRatingsForTesting: async (_source, _args, { ratingsAPI }) => {
    return ratingsAPI.deleteRatingsForTesting();
  },

  rate: async (_source, { id, rating, login }, { ratingsAPI }) => {
    return ratingsAPI.addRating(id, rating, login);
  },
};

const Recipe: RecipeResolvers<Context> = {
  rating: async (source, _args, { ratingsAPI }) => {
    return ratingsAPI.getRating(source.id);
  },
};

export const resolvers: Resolvers<Context> = {
  Query,
  Mutation,
  Recipe,
};
