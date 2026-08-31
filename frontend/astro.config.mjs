import node from "@astrojs/node";
import svelte from "@astrojs/svelte";
import vue from "@astrojs/vue";
import { defineConfig } from "astro/config";

// https://astro.build/config
export default defineConfig({
  output: "server",
  adapter: node({
    mode: "middleware",
  }),
  integrations: [svelte(), vue()],
});
