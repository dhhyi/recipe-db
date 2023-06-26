import { RESTDataSource } from "@apollo/datasource-rest";
import { Rating } from "./graphql.js";

export class RatingsAPI extends RESTDataSource {
  constructor() {
    super();
    this.baseURL = process.env.REST_ENDPOINT + "/ratings/";
  }

  async deleteRatingsForTesting(): Promise<boolean> {
    return this.delete("").then(() => {
      return true;
    });
  }

  async getRating(id: string): Promise<Rating> {
    return this.get(id).then((rating) => ({
      average: rating.rating,
      count: rating.count,
    }));
  }

  async addRating(id: string, rating: number, login: string): Promise<number> {
    return this.put(id, {
      body: `rating=${rating}&login=${login}`,
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
      },
    }).then((rating) => rating.rating);
  }

  parseBody(response) {
    if (response.status >= 400) {
      return response.text();
    } else if (response.status === 204) {
      return null;
    } else {
      return response.json();
    }
  }
}
