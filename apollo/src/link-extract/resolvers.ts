import {
  type ExtractedLink,
  type LinkResolvers,
} from "../generated/graphql.js";

import type { LinkExtractContext } from "./context.js";

const Link: LinkResolvers<LinkExtractContext> = {
  extracted: async (
    source,
    _args,
    { linkExtractAPI },
  ): Promise<ExtractedLink> => {
    return source.url?.startsWith("http")
      ? await linkExtractAPI.getExtractedLink(source.url)
      : null;
  },
};

export const resolvers = {
  Link,
};
