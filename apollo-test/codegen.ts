import type { CodegenConfig } from "@graphql-codegen/cli";

const config: CodegenConfig = {
  overwrite: true,
  schema: "recipe-db.graphqls",
  documents: "src/**/*.graphql",
  generates: {
    "src/generated/": {
      preset: "client",
    },
  },
};

export default config;
