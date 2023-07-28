import { RESTDataSource } from "@apollo/datasource-rest";
import { type GraphQLError } from "graphql";

import { type RecipeInput, type Recipe } from "../generated/graphql.js";
import { type RecipeHandlers } from "../handlers.js";

export class RecipesAPI extends RESTDataSource {
  constructor() {
    super();
    this.baseURL = process.env.REST_ENDPOINT + "/recipes/";
  }

  async deleteRecipesForTesting(): Promise<boolean> {
    return await this.delete("").then(() => {
      return true;
    });
  }

  async getRecipes(): Promise<Recipe[]> {
    return await this.get("");
  }

  async getRecipe(id: string): Promise<Recipe> {
    return await this.get(id);
  }

  async createRecipe(
    handlers: RecipeHandlers,
    value: RecipeInput,
  ): Promise<Recipe> {
    const recipeBase: Partial<RecipeInput> = {};
    for (const key in value) {
      const handler = handlers[key];
      if (!handler) {
        recipeBase[key] = value[key];
      }
    }

    const recipe = await this.post("", { body: recipeBase });
    const id = recipe.id;

    for (const key in handlers) {
      const handler = handlers[key];
      if (handler && value[key]) {
        await handler(id, value[key]);
      }
    }

    return recipe;
  }

  async updateRecipe(
    handlers: RecipeHandlers,
    id: string,
    value: RecipeInput,
  ): Promise<Recipe> {
    const recipeBase: Partial<RecipeInput> = {};
    for (const key in value) {
      const handler = handlers[key];
      if (handler) {
        await handler(id, value[key]);
      } else {
        recipeBase[key] = value[key];
      }
    }

    return await this.patch(id, { body: recipeBase });
  }

  async deleteRecipe(id: string): Promise<boolean> {
    return await this.delete(id)
      .then(() => {
        return true;
      })
      .catch((err: GraphQLError) => {
        const response = err.extensions?.response as { status: number };
        if (response?.status === 404) {
          return false;
        }
        throw err;
      });
  }
}
