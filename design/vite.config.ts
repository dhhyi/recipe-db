import tailwindcss from "@tailwindcss/vite";
import { defineConfig } from "vite";

export default defineConfig({
  plugins: [tailwindcss()],
  build: {
    rolldownOptions: {
      output: {
        assetFileNames: "design/[name]-[hash].[ext]",
        chunkFileNames: "design/[name]-[hash].js",
        entryFileNames: "design/[name]-[hash].js",
      },
    },
    minify: true,
    cssMinify: true,
  },
});
