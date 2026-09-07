import { RESTDataSource } from "@apollo/datasource-rest";

import { type ExtractedLink } from "../generated/graphql.js";

export class LinkExtractAPI extends RESTDataSource {
  constructor() {
    super();
    this.baseURL = process.env.REST_ENDPOINT + "/link-extract/";
  }

  async getExtractedLink(url: string): Promise<ExtractedLink> {
    return await this.get<ExtractedLink>("", {
      params: { url },
    })
      .then((link) => {
        if (!link.canonical) {
          link.canonical = url;
        }
        return link;
      })
      .catch(() => null);
  }
}
