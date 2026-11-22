import type { StorybookConfig } from "@storybook/web-components-vite";

const config: StorybookConfig = {
  stories: ["../src/**/*.stories.@(js|jsx|mjs|ts|tsx)"],
  addons: [],
  framework: "@storybook/web-components-vite",
  staticDirs: [{ from: "../src/assets", to: "/assets" }],
  viteFinal: async (config) => ({ ...config, base: "/design/" }),
};
export default config;
