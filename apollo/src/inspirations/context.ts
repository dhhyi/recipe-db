import { InspirationsAPI } from "./api.js";

export const inspirationsContext = {
  inspirationsAPI: new InspirationsAPI(),
};

export type InspirationsContext = typeof inspirationsContext;
