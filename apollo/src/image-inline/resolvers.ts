import { type ExtractedLinkResolvers } from "../generated/graphql.js";

import { type ImageInlineContext } from "./context.js";

const ExtractedLink: ExtractedLinkResolvers<ImageInlineContext> = {
  inlinedFavicon: async (source, _args, { imageInlineAPI }) => {
    if (source.favicon?.startsWith("data:")) {
      return source.favicon;
    } else if (source.favicon?.startsWith("http")) {
      return await imageInlineAPI.getInlinedImage(source.favicon);
    }
    return null;
  },
};

export const resolvers = {
  ExtractedLink,
};
