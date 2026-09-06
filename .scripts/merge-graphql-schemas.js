const path = require("path");
const fs = require("fs");
const {
  projectRoot,
  getAvailableProjects,
  getProjectConfig,
  checkInstallDependencies,
} = require("./shared");

checkInstallDependencies();

const { loadFilesSync } = require("@graphql-tools/load-files");
const { mergeTypeDefs } = require("@graphql-tools/merge");
const { print } = require("graphql");

const loadedFiles = loadFilesSync(
  path.join(projectRoot, "apollo/src/**/*.gql"),
);
const typeDefs = mergeTypeDefs(loadedFiles);
const printedTypeDefs = print(typeDefs);

getAvailableProjects()
  .map((project) => ({ project, config: getProjectConfig(project) }))
  .filter(({ config }) => config.graphqlSchema)
  .forEach(({ project, config }) => {
    const outputDirectory = path.join(
      projectRoot,
      project,
      config.graphqlSchema,
    );
    fs.mkdirSync(outputDirectory, { recursive: true });
    const schemaPath = path.join(outputDirectory, "recipe-db.graphqls");
    console.log(
      "Writing merged schema to " + schemaPath.replace(projectRoot + "/", ""),
    );
    fs.writeFileSync(schemaPath, printedTypeDefs);
  });
