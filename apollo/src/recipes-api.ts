import { RESTDataSource } from "@apollo/datasource-rest";

export class RecipesAPI extends RESTDataSource {
  constructor() {
    super();
    this.baseURL = process.env.REST_ENDPOINT + "/recipes/";
  }

  async getRecipes() {
    return this.get("");
  }

  async getRecipe(id: string) {
    return this.get(id);
  }
}
