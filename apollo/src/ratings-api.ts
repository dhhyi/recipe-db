import { RESTDataSource } from "@apollo/datasource-rest";

export class RatingsAPI extends RESTDataSource {
  constructor() {
    super();
    this.baseURL = process.env.REST_ENDPOINT + "/ratings/";
  }

  async getRating(id: string) {
    return this.get(id).then((rating) => ({
      average: rating.rating,
      count: rating.count,
    }));
  }

  async addRating(id: string, rating: number, login: string) {
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
    } else {
      return response.json();
    }
  }
}
