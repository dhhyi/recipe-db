import { storybookTest } from "@storybook/addon-vitest/vitest-plugin";
import { playwright } from "@vitest/browser-playwright";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig, mergeConfig } from "vitest/config";

import viteConfig from "./vite.config.ts";

const dirname = path.dirname(fileURLToPath(import.meta.url));

export default mergeConfig(
  viteConfig,
  defineConfig({
    plugins: [
      storybookTest({
        configDir: path.join(dirname, ".storybook"),
      }),
    ],
    test: {
      setupFiles: ["./vitest.storybook.setup.ts"],
      browser: {
        enabled: true,
        provider: playwright(),
        headless: true,
        instances: [{ browser: "chromium" }],
      },
    },
  }),
);
