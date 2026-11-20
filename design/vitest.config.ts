import { storybookTest } from "@storybook/addon-vitest/vitest-plugin";
import { playwright } from "@vitest/browser-playwright";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig, mergeConfig } from "vitest/config";

import viteConfig from "./vite.config.ts";

const dirname = path.dirname(fileURLToPath(import.meta.url));

const browser = {
  enabled: true,
  provider: playwright(),
  headless: true,
  instances: [{ browser: "chromium" as const }],
};

export default mergeConfig(
  viteConfig,
  defineConfig({
    test: {
      projects: [
        {
          extends: true,
          plugins: [
            storybookTest({
              configDir: path.join(dirname, ".storybook"),
            }),
          ],
          test: {
            name: "storybook",
            browser,
          },
        },
        {
          extends: true,
          test: {
            name: "browser",
            include: ["src/**/*.test.ts"],
            browser,
          },
        },
        {
          extends: true,
          test: {
            name: "visual-touch",
            include: ["src/stories/header.visual.touch.test.ts"],
            browser: {
              ...browser,
              provider: playwright({ contextOptions: { hasTouch: true } }),
            },
          },
        },
        {
          extends: true,
          test: {
            name: "visual-desktop",
            include: ["src/stories/header.visual.desktop.test.ts"],
            browser,
          },
        },
      ],
    },
  }),
);
