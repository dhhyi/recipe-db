import { RESTDataSource } from "@apollo/datasource-rest";

import { type Recipe } from "../generated/graphql.js";

export class RecipesAPI extends RESTDataSource {
  constructor() {
    super();
    this.baseURL = process.env.REST_ENDPOINT + "/recipes/";
  }

  async getRecipes(): Promise<Recipe[]> {
    return await this.get("");
  }

  async getRecipe(id: string): Promise<Recipe> {
    return await this.get(id);
  }
}
