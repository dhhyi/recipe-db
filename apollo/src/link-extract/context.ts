import { LinkExtractAPI } from "./api.js";

export const context = {
  linkExtractAPI: new LinkExtractAPI(),
};

export type LinkExtractContext = typeof context;
