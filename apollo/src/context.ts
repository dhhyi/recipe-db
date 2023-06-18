import { RecipesAPI } from "./recipes-api.js";
import { RatingsAPI } from "./ratings-api.js";

export const context = {
  recipesAPI: new RecipesAPI(),
  ratingsAPI: new RatingsAPI(),
};

export type Context = typeof context;
