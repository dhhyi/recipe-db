import type { CodegenConfig } from "@graphql-codegen/cli";

const config: CodegenConfig = {
  overwrite: true,
  schema: "merged-schema.graphql",
  generates: {
    "src/generated/graphql.ts": {
      plugins: [
        "typescript",
        "typescript-operations",
        "typescript-document-nodes",
      ],
      config: {
        // avoidOptionals: {
        //   field: true,
        //   inputValue: true,
        //   object: true,
        //   defaultValue: true,
        // },
        maybeValue: "T",
      },
    },
  },
  documents: "src/**/*.graphql",
};

export default config;
