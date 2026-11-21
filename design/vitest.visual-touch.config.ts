import { playwright } from "@vitest/browser-playwright";
import { defineConfig, mergeConfig } from "vitest/config";

import viteConfig from "./vite.config.ts";

export default mergeConfig(
  viteConfig,
  defineConfig({
    test: {
      include: ["src/components/header.visual.touch.test.ts"],
      browser: {
        enabled: true,
        provider: playwright({ contextOptions: { hasTouch: true } }),
        headless: true,
        instances: [{ browser: "chromium" }],
      },
    },
  }),
);
