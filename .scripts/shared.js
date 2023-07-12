const path = require("path");
const fs = require("fs");
const yaml = require("js-yaml");
const { globSync } = require("glob");

const scriptRoot = __dirname;
const projectRoot = path.normalize(path.join(__dirname, ".."));

function getAvailableProjects() {
  return globSync("*/.project.yaml", { cwd: projectRoot }).map((file) =>
    path.dirname(file)
  );
}

function languageFile(project) {
  return path.join(project, ".project.yaml");
}

function getProjectConfig(project) {
  const projectYaml = path.join(projectRoot, project, ".project.yaml");
  return yaml.load(fs.readFileSync(projectYaml, "utf8"));
}

module.exports = {
  projectRoot,
  scriptRoot,
  getAvailableProjects,
  languageFile,
  getProjectConfig,
};
