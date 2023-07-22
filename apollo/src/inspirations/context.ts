import { InspirationsAPI } from "./api.js";

export const context = {
  inspirationsAPI: new InspirationsAPI(),
};

export type InspirationsContext = typeof context;
