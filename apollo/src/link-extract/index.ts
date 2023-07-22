import { type ExtractedLink } from "../generated/graphql.js";
import { type ImageInlineAPI } from "../image-inline/api.js";

import type { LinkExtractAPI } from "./api.js";

export { LinkExtractAPI } from "./api.js";

export const linkExtractTypeDefs: string = require("./typedefs.gql");

export async function urlExtraction(
  context: {
    linkExtractAPI: LinkExtractAPI;
    imageInlineAPI: ImageInlineAPI;
  },
  url: string
): Promise<ExtractedLink> {
  return await context.linkExtractAPI
    .getExtractedLink(url)
    .then(async (response) => {
      if (response.favicon?.startsWith("http")) {
        response.favicon = await context.imageInlineAPI.getInlinedImage(
          response.favicon
        );
      }
      return response;
    })
    .catch<ExtractedLink>(() => ({
      title: url,
    }));
}
