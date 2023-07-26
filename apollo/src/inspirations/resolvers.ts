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
};

const Recipe: RecipeResolvers<InspirationsContext> = {
  inspirations: async (source, _args, context) => {
    const inspirations = await context.inspirationsAPI.getInspirations(
      source.id
    );
    return inspirations.map((url) => ({ url }));
  },
};

export const resolvers: Resolvers<InspirationsContext> = {
  Mutation,
  Recipe,
};
