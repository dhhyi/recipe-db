import type {
  MutationResolvers,
  RecipeResolvers,
  Resolvers,
} from "../generated/graphql.js";

import type { InspirationsContext } from "./context.js";

const Mutation: MutationResolvers<InspirationsContext> = {
  deleteInspirationsForTesting: async (_source, _args, { inspirationsAPI }) => {
    return await inspirationsAPI.deleteInspirationsForTesting();
  },

  setInspirations: async (
    _source,
    { id, inspirations },
    { inspirationsAPI }
  ) => {
    return await inspirationsAPI.setInspirations(id, inspirations);
  },
};

const Recipe: RecipeResolvers<InspirationsContext> = {
  inspirations: async (
    source,
    _args,
    { inspirationsAPI, linkExtractAPI, imageInlineAPI }
  ) => {
    const inspirations = await inspirationsAPI.getInspirations(source.id);
    return await Promise.all(
      inspirations.map(async (url) => {
        const response = await linkExtractAPI.getExtractedLink(url);
        if (response.favicon?.startsWith("http")) {
          response.favicon = await imageInlineAPI.getInlinedImage(
            response.favicon
          );
        }
        return response;
      })
    );
  },
};

export const inspirationsResolvers: Resolvers<InspirationsContext> = {
  Mutation,
  Recipe,
};
