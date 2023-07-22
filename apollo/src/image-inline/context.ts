import { ImageInlineAPI } from "./api.js";

export const context = {
  imageInlineAPI: new ImageInlineAPI(),
};

export type ImageInlineContext = typeof context;
