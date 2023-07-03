module.exports = {
  env: {
    browser: true,
    es2021: true,
  },
  plugins: ["unused-imports"],
  overrides: [
    {
      extends: [
        "standard-with-typescript",
        "plugin:astro/recommended",
        "prettier",
      ],
      files: ["*.ts", "*.tsx"],
      parser: "@typescript-eslint/parser",
      processor: "@graphql-eslint/graphql",
      rules: {
        "@typescript-eslint/strict-boolean-expressions": "off",
        "@typescript-eslint/triple-slash-reference": "off",
      },
    },
    {
      extends: [
        "standard-with-typescript",
        "plugin:astro/recommended",
        "prettier",
      ],
      files: ["*.astro"],
      parser: "astro-eslint-parser",
      parserOptions: {
        parser: "@typescript-eslint/parser",
        extraFileExtensions: [".astro"],
        additionalFileExtensions: [".astro"],
      },
      rules: {
        "@typescript-eslint/strict-boolean-expressions": "off",
      },
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
  ignorePatterns: ["src/generated/*.ts"],
};
