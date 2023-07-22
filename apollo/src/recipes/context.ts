import { RecipesAPI } from "./api.js";

export const context = {
  recipesAPI: new RecipesAPI(),
};

export type RecipesContext = typeof context;
