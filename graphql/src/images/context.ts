import { ImagesAPI } from "./api.js";

export const context = {
  imagesAPI: new ImagesAPI(),
};

export type ImagesContext = typeof context;
