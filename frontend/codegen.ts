import type { CodegenConfig } from "@graphql-codegen/cli";

const config: CodegenConfig = {
  overwrite: true,
  schema: "recipe-db.graphqls",
  generates: {
    "src/generated/graphql.ts": {
      plugins: [
        "typescript",
        "typescript-operations",
        require.resolve("./codegen-typescript-minified-document-nodes-plugin"),
      ],
      config: {
        // avoidOptionals: {
        //   field: true,
        //   inputValue: true,
        //   object: true,
        //   defaultValue: true,
        // },
        maybeValue: "T",
        documentMode: "documentNode",
      },
    },
  },
  documents: "src/**/*.graphql",
};

export default config;
