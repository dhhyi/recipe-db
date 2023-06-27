const { globSync } = require("glob");
const cp = require("child_process");
const path = require("path");
const fs = require("fs");
const { languageFile, projectRoot, scriptRoot } = require("./shared");

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

let command;
if (fs.existsSync(path.join(projectRoot, project, "test.sh"))) {
  command = "sh -e test.sh";
} else {
  const packageJsonPath = path.join(projectRoot, project, "package.json");
  if (fs.existsSync(packageJsonPath)) {
    const packageJson = JSON.parse(
      fs.readFileSync(packageJsonPath, {
        encoding: "utf8",
      })
    );
    if (packageJson.scripts?.test) {
      command = "npm run test";
    }
  }
}

if (!command) {
  console.error("No test script found");
  process.exit(1);
}

const commandLine = `node ${scriptRoot}/run-in-devcontainer.js ${project} ${command}`;
cp.execSync(commandLine, { stdio: "inherit" });
