import { RESTDataSource } from "@apollo/datasource-rest";
import { Recipe } from "./graphql.js";

export class RecipesAPI extends RESTDataSource {
  constructor() {
    super();
    this.baseURL = process.env.REST_ENDPOINT + "/recipes/";
  }

  async getRecipes(): Promise<Recipe[]> {
    return this.get("");
  }

  async getRecipe(id: string): Promise<Recipe> {
    return this.get(id);
  }
}
