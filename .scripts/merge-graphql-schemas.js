const path = require("path");
const fs = require("fs");
const { projectRoot, checkInstallDependencies } = require("./shared");

checkInstallDependencies();

const { loadFilesSync } = require("@graphql-tools/load-files");
const { mergeTypeDefs } = require("@graphql-tools/merge");
const { print } = require("graphql");

const loadedFiles = loadFilesSync(
  path.join(projectRoot, "apollo/src/**/*.gql"),
);
const typeDefs = mergeTypeDefs(loadedFiles);
const printedTypeDefs = print(typeDefs);

const glob = require("glob");
glob
  .sync(path.join(projectRoot, "**/.needs-graphql-schema"))
  .forEach((file) => {
    const dir = path.dirname(file);
    const schemaPath = path.join(dir, "recipe-db.graphqls");
    console.log(
      "Writing merged schema to " + schemaPath.replace(projectRoot + "/", ""),
    );
    fs.writeFileSync(schemaPath, printedTypeDefs);
  });
