const cp = require("child_process");
const fs = require("fs");
const { languageFile, scriptRoot } = require("./shared");

const project = process.argv[2];
if (!project) {
  console.error("Missing project name");
  process.exit(1);
} else if (!fs.existsSync(languageFile(project))) {
  console.error(`Project ${project} is missing`);
  process.exit(1);
} else if (!project.endsWith("-test")) {
  console.error("Project name must end with -test");
  process.exit(1);
}

const commandLine = `node ${scriptRoot}/run-in-devcontainer.js ${project} test`;
cp.execSync(commandLine, { stdio: "inherit" });
