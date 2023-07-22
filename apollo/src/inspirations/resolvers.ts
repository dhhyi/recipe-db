import type {
  MutationResolvers,
  RecipeResolvers,
  Resolvers,
} from "../generated/graphql.js";
import { urlExtraction } from "../link-extract/index.js";

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
  inspirations: async (source, _args, context) => {
    const inspirations = await context.inspirationsAPI.getInspirations(
      source.id
    );
    return await Promise.all(
      inspirations.map(async (url) =>
        url?.startsWith("http")
          ? await urlExtraction(context, url)
          : { title: url }
      )
    );
  },
};

export const inspirationsResolvers: Resolvers<InspirationsContext> = {
  Mutation,
  Recipe,
};
