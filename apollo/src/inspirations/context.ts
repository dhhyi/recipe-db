import { ImageInlineAPI } from "../image-inline/api.js";
import { LinkExtractAPI } from "../link-extract/api.js";

import { InspirationsAPI } from "./api.js";

export const inspirationsContext = {
  inspirationsAPI: new InspirationsAPI(),
  linkExtractAPI: new LinkExtractAPI(),
  imageInlineAPI: new ImageInlineAPI(),
};

export type InspirationsContext = typeof inspirationsContext;
