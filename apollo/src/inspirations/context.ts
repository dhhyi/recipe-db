import { LinkExtractAPI } from "../link-extract/api.js";

import { InspirationsAPI } from "./api.js";

export const inspirationsContext = {
  inspirationsAPI: new InspirationsAPI(),
  linkExtractAPI: new LinkExtractAPI(),
};

export type InspirationsContext = typeof inspirationsContext;
