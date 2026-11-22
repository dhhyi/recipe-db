import { addons } from "storybook/manager-api";
import { themes } from "storybook/theming";

addons.setConfig({
  theme: {
    ...themes.normal,
    brandTitle: "RezeptDB",
    brandUrl: "/",
    brandImage: "./assets/banner.svg",
    brandTarget: "_self",
  },
});
