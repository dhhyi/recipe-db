import { RatingsAPI } from "./api.js";

export const context = {
  ratingsAPI: new RatingsAPI(),
};

export type RatingsContext = typeof context;
