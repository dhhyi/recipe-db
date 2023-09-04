import { RESTDataSource } from "@apollo/datasource-rest";

import { type ImageMetadata } from "../generated/graphql.js";

export class ImagesAPI extends RESTDataSource {
  constructor() {
    super();
    this.baseURL = process.env.REST_ENDPOINT + "/images/";
  }

  async getImageMetadata(recipeId: string): Promise<ImageMetadata> {
    return await this.get(`${recipeId}/meta`).catch((err) => {
      if (err.extensions.response.status === 404) {
        return null;
      }
      throw err;
    });
  }

  async uploadImage(
    recipeId: string,
    mimetype: string,
    body: Buffer,
  ): Promise<boolean> {
    return await this.post(`${recipeId}`, {
      headers: { "Content-Type": mimetype },
      body,
    }).then(() => true);
  }

  async deleteImagesForTesting(): Promise<boolean> {
    return await this.delete("").then(() => true);
  }
}
