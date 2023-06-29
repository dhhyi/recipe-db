import { RESTDataSource } from "@apollo/datasource-rest";
import { type GraphQLError } from "graphql";

import { type Recipe } from "../generated/graphql.js";

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

  async createRecipe(value: string): Promise<Recipe> {
    return await this.post("", { body: value });
  }

  async updateRecipe(id: string, value: string): Promise<Recipe> {
    return await this.patch(id, { body: value });
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
