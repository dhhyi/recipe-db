import { RESTDataSource } from "@apollo/datasource-rest";
import { GraphQLError } from "graphql";

import { type Recipe, type RecipeInput } from "../generated/graphql.js";
import { type RecipeHandlers } from "../handlers.js";

// the recipes service rejects a missing/empty name with a 400 - surface it as a field validation error
function rethrowAsValidationError(err: GraphQLError): never {
  const response = err.extensions?.response as
    { status: number; body?: { message?: string } } | undefined;
  if (
    response?.status === 400 &&
    response.body?.message === "Missing field value for name"
  ) {
    throw new GraphQLError(response.body.message, {
      extensions: { code: "BAD_USER_INPUT", field: "name" },
    });
  }
  throw err;
}

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

    const recipe = await this.post("", { body: recipeBase }).catch(
      rethrowAsValidationError,
    );
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

    return await this.patch(id, { body: recipeBase }).catch(
      rethrowAsValidationError,
    );
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
