import type { Preview } from "@storybook/web-components-vite";

const prefersDark = window.matchMedia("(prefers-color-scheme: dark)").matches;

const preview: Preview = {
  parameters: {
    controls: {
      matchers: {
        color: /(background|color)$/i,
        date: /Date$/i,
      },
    },
    backgrounds: {
      /* Values mirror blades' --pico-background-color for each scheme. */
      options: {
        light: { name: "Light", value: "#fff" },
        dark: { name: "Dark", value: "#13171f" },
      },
    },
  },
  initialGlobals: {
    backgrounds: { value: prefersDark ? "dark" : "light" },
  },
  decorators: [
    (story, context) => {
      const background = context.globals.backgrounds;
      const value =
        typeof background === "string" ? background : background?.value;
      document.documentElement.setAttribute(
        "data-theme",
        value === "dark" ? "dark" : "light",
      );
      return story();
    },
  ],
};

export default preview;
