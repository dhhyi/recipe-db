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
  inspirations: async (source, _args, { inspirationsAPI }) => {
    return await inspirationsAPI.getInspirations(source.id);
  },
};

export const inspirationsResolvers: Resolvers<InspirationsContext> = {
  Mutation,
  Recipe,
};
