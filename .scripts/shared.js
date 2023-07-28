const path = require("path");
const fs = require("fs");
const cp = require("child_process");

const scriptRoot = __dirname;
const projectRoot = path.normalize(path.join(__dirname, ".."));

function checkInstallDependencies() {
  if (!fs.existsSync(path.join(projectRoot, "node_modules", ".modules.yaml"))) {
    console.log("Installing dependencies");
    cp.execSync("npm exec pnpm -- i --prod --ignore-scripts", {
      stdio: "inherit",
    });
  }
}

function getAvailableProjects() {
  const { globSync } = require("glob");
  return globSync("*/.project.yaml", { cwd: projectRoot }).map((file) =>
    path.dirname(file),
  );
}

function languageFile(project) {
  return path.join(project, ".project.yaml");
}

function getProjectConfig(project) {
  const projectYaml = path.join(projectRoot, project, ".project.yaml");
  const yaml = require("js-yaml");
  return yaml.load(fs.readFileSync(projectYaml, "utf8"));
}

module.exports = {
  projectRoot,
  scriptRoot,
  getAvailableProjects,
  languageFile,
  getProjectConfig,
  checkInstallDependencies,
};
