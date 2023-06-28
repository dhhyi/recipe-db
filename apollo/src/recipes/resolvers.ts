import type { QueryResolvers, Resolvers } from "../generated/graphql.js";

import type { RecipesContext } from "./context.js";

const Query: QueryResolvers<RecipesContext> = {
  recipes: async (_source, _args, { recipesAPI }) => {
    return await recipesAPI.getRecipes();
  },
  recipe: async (_source, { id }, { recipesAPI }) => {
    return await recipesAPI.getRecipe(id);
  },
};

export const recipesResolvers: Resolvers<RecipesContext> = {
  Query,
};
