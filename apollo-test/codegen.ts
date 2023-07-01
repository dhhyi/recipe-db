import type { CodegenConfig } from "@graphql-codegen/cli";

const config: CodegenConfig = {
  overwrite: true,
  schema: process.env.PRE_COMMIT
    ? "merged-schema.graphql"
    : "http://traefik/graphql",
  documents: "src/**/*.graphql",
  generates: {
    "src/generated/": {
      preset: "client",
    },
  },
};

export default config;
