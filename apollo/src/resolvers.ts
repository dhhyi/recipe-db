import { Context } from "./context.js";

const Query = {
  test: () => "Test Success, GraphQL server is up & running !!",

  recipes: async (_source, _args, { recipesAPI }: Context) => {
    return recipesAPI.getRecipes();
  },
  recipe: async (_source, { id }, { recipesAPI }: Context) => {
    return recipesAPI.getRecipe(id);
  },

  rating: async (_source, { id }, { ratingsAPI }: Context) => {
    return ratingsAPI.getRating(id);
  },
};

const Mutation = {
  rate: async (_source, { id, rating, login }, { ratingsAPI }: Context) => {
    return ratingsAPI.addRating(id, rating, login);
  },
};

const Recipe = {
  rating: async (source, _args, { ratingsAPI }: Context) => {
    return ratingsAPI.getRating(source.id);
  },
};

export const resolvers = {
  Query,
  Mutation,
  Recipe,
};
