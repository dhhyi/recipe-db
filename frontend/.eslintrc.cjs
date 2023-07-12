module.exports = {
  env: {
    browser: true,
    es2021: true,
  },
  plugins: ["unused-imports"],
  overrides: [
    {
      files: ["*.mjs"],
      extends: ["standard", "prettier"],
      parserOptions: {
        sourceType: "module",
      },
    },
    {
      files: ["*.cjs"],
      extends: ["standard", "prettier"],
      parserOptions: {
        sourceType: "script",
      },
    },
    {
      files: ["*.js"],
      extends: ["standard", "prettier"],
      parserOptions: {
        sourceType: "module",
      },
    },
    {
      files: ["*.ts", "*.tsx"],
      extends: [
        "standard-with-typescript",
        "plugin:astro/recommended",
        "prettier",
      ],
      parser: "@typescript-eslint/parser",
      processor: "@graphql-eslint/graphql",
      rules: {
        "@typescript-eslint/strict-boolean-expressions": "off",
        "@typescript-eslint/triple-slash-reference": "off",
      },
    },
    {
      files: ["*.astro"],
      extends: [
        "standard-with-typescript",
        "plugin:astro/recommended",
        "prettier",
      ],
      parser: "astro-eslint-parser",
      parserOptions: {
        parser: "@typescript-eslint/parser",
        extraFileExtensions: [".astro"],
      },
      rules: {
        "@typescript-eslint/strict-boolean-expressions": "off",
      },
    },
    {
      files: ["*.svelte"],
      extends: ["plugin:svelte/recommended", "prettier"],
      parser: "svelte-eslint-parser",
      parserOptions: {},
      rules: {
        "no-unused-vars": "error",
      },
    },
    {
      files: ["*.vue"],
      extends: ["plugin:vue/vue3-recommended", "prettier"],
      parser: "vue-eslint-parser",
      parserOptions: {},
      rules: {},
    },
    {
      extends: ["plugin:@graphql-eslint/operations-recommended", "prettier"],
      files: ["*.graphql"],
      rules: {
        "@graphql-eslint/require-description": "off",
        "@graphql-eslint/strict-id-in-types": "off",
        "@graphql-eslint/require-id-when-available": "off",
        "@graphql-eslint/executable-definitions": "off",
      },
    },
  ],
  parserOptions: {
    ecmaVersion: "latest",
    sourceType: "module",
    project: "./tsconfig.json",
    schema: "./merged-schema.graphql",
    operations: ["./src/shared/**/*.graphql"],
  },
  rules: {
    "import/order": [
      "error",
      {
        groups: ["builtin", "external", "parent", "sibling", "index"],
        "newlines-between": "always",
        alphabetize: {
          order: "asc",
          caseInsensitive: false,
        },
      },
    ],
  },
  ignorePatterns: ["src/generated/*.ts", "dist/*"],
};
