import { RecipesAPI } from "./api.js";

export const recipesContext = {
  recipesAPI: new RecipesAPI(),
};

export type RecipesContext = typeof recipesContext;
