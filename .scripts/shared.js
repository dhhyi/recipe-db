const path = require("path");
const fs = require("fs");

const scriptRoot = __dirname;
const projectRoot = path.normalize(path.join(__dirname, ".."));

function getAvailableProjects() {
  const regex = /^project\.([\w-]+)\.language\.yaml$/;

  return fs
    .readdirSync(projectRoot)
    .filter((file) => regex.test(file))
    .map((file) => regex.exec(file)[1]);
}

function languageFile(project) {
  return `project.${project}.language.yaml`;
}

module.exports = {
  projectRoot,
  scriptRoot,
  getAvailableProjects,
  languageFile,
};
