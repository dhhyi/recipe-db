import tseslint from "typescript-eslint";
import storybook from "eslint-plugin-storybook";

export default tseslint.config(
  { ignores: ["dist", "storybook-static"] },
  ...tseslint.configs.recommended,
  ...storybook.configs["flat/recommended"],
);
