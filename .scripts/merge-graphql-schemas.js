const path = require("path");
const fs = require("fs");
const cp = require("child_process");
const {
  projectRoot,
  scriptRoot,
  getAvailableProjects,
  getProjectConfig,
  checkInstallDependencies,
} = require("./shared");

checkInstallDependencies();

const printedTypeDefs = cp.execSync(
  `node ${path.join(scriptRoot, "run-in-devcontainer.js")} graphql cargo run --release -- print-schema`,
  { cwd: projectRoot, encoding: "utf-8" },
);

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
