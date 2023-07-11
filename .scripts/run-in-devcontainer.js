const cp = require("child_process");
const fs = require("fs");
const { languageFile, getProjectConfig } = require("./shared");

const project = process.argv[2];
const command = process.argv.slice(3);

if (!project) {
  console.error("Missing project name");
  process.exit(1);
} else if (!fs.existsSync(languageFile(project))) {
  console.error(`Project ${project} is missing`);
  process.exit(1);
} else if (command.length === 0) {
  console.error("Missing command");
  process.exit(1);
}

const projectConfig = getProjectConfig(project);
let runCommand;
if (command.length === 1 && command[0] === "test") {
  if (!projectConfig.test) {
    console.error("Project does not have test command");
    process.exit(1);
  }
  const projectTestCommand = projectConfig.test
    .split("\n")
    .filter(Boolean)
    .join(" && ");

  runCommand = ["sh", "-ce", projectTestCommand];
} else if (command.length === 1 && command[0] === "precommit") {
  if (!projectConfig.precommit) {
    console.error("Project does not have precommit command");
    process.exit(1);
  }
  const projectPrecommitCommand =
    "export PRE_COMMIT=1 && " +
    projectConfig.precommit.split("\n").filter(Boolean).join(" && ");

  runCommand = ["sh", "-ce", projectPrecommitCommand];
} else {
  runCommand = command;
}

let containerId = null;

try {
  const commandLine = `devcontainer up --workspace-folder ${project}`;
  // if (process.env.PRE_COMMIT) {
  //   commandLine += " --remove-existing-container";
  // }
  const output = cp.execSync(commandLine, {
    stdio: ["ignore", "pipe", "inherit"],
    encoding: "utf-8",
  });
  const json = JSON.parse(output);
  if (json?.outcome !== "success") {
    throw new Error("Failed to start devcontainer");
  }

  containerId = json?.containerId;

  const result = cp.spawnSync(
    "devcontainer",
    ["exec", "--workspace-folder", project, ...runCommand],
    { stdio: "inherit", encoding: "utf-8" }
  );

  if (result.status !== 0) {
    console.error(`Command failed with exit code ${result.status}`);
    process.exit(result.status);
  }
} finally {
  if (containerId) {
    cp.execSync(`docker stop ${containerId}`);
  }
}
