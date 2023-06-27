import type { QueryResolvers, Resolvers } from "../generated/graphql.js";
import type { RecipesContext } from "./context.js";

const Query: QueryResolvers<RecipesContext> = {
  recipes: async (_source, _args, { recipesAPI }) => {
    return recipesAPI.getRecipes();
  },
  recipe: async (_source, { id }, { recipesAPI }) => {
    return recipesAPI.getRecipe(id);
  },
};

export const recipesResolvers: Resolvers<RecipesContext> = {
  Query,
};
