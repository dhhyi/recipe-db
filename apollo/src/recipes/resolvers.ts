import type {
  MutationResolvers,
  QueryResolvers,
  Resolvers,
} from "../generated/graphql.js";

import type { RecipesContext } from "./context.js";

const Query: QueryResolvers<RecipesContext> = {
  recipes: async (_source, _args, { recipesAPI }) => {
    return await recipesAPI.getRecipes();
  },
  recipe: async (_source, { id }, { recipesAPI }) => {
    return await recipesAPI.getRecipe(id);
  },
};

const Mutation: MutationResolvers<RecipesContext> = {
  deleteRecipesForTesting: async (_source, _args, { recipesAPI }) => {
    return await recipesAPI.deleteRecipesForTesting();
  },

  createRecipe: async (_source, { value }, { recipesAPI, handlers }) => {
    return await recipesAPI.createRecipe(handlers, value);
  },

  updateRecipe: async (_source, { id, value }, { recipesAPI, handlers }) => {
    return await recipesAPI.updateRecipe(handlers, id, value);
  },

  deleteRecipe: async (_source, { id }, { recipesAPI }) => {
    return await recipesAPI.deleteRecipe(id);
  },
};

export const resolvers: Resolvers<RecipesContext> = {
  Query,
  Mutation,
};
