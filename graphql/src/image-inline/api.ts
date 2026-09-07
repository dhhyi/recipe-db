import { RESTDataSource } from "@apollo/datasource-rest";

export class ImageInlineAPI extends RESTDataSource {
  constructor() {
    super();
    this.baseURL = process.env.REST_ENDPOINT + "/image-inline/";
  }

  async getInlinedImage(url: string): Promise<string> {
    return await this.get("", {
      params: { url },
    });
  }
}
