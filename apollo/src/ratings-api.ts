import { RESTDataSource } from "@apollo/datasource-rest";

export class RatingsAPI extends RESTDataSource {
  constructor() {
    super();
    this.baseURL = process.env.REST_ENDPOINT + "/ratings/";
  }

  async getRating(id: string) {
    return this.get(id).then((rating) => rating.rating);
  }

  async addRating(id: string, rating: number) {
    if (isNaN(rating)) throw new Error("Rating must be a number");
    if (rating % 1 !== 0) throw new Error("Rating must be a whole number");
    if (rating < 0 || rating > 5)
      throw new Error("Rating must be between 0 and 5");
    return this.put(id, {
      body: `rating=${rating}`,
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
      },
    }).then((rating) => rating.rating);
  }
}
