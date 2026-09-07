import { TraefikAPI } from "./api.js";

export const context = {
  traefikAPI: new TraefikAPI(),
};

export type TraefikContext = typeof context;
