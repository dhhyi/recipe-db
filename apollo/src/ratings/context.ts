import { RatingsAPI } from "./api.js";

export const ratingsContext = {
  ratingsAPI: new RatingsAPI(),
};

export type RatingsContext = typeof ratingsContext;
