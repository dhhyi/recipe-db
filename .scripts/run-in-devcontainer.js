const cp = require("child_process");
const fs = require("fs");
const path = require("path");
const { languageFile, getProjectConfig, projectRoot } = require("./shared");

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
let stopAfter = true;

try {
  // search for existing container
  const workspaceDevcontainerJson = path.join(
    projectRoot,
    project,
    ".devcontainer",
    "devcontainer.json",
  );
  const existingRunningContainerID = cp
    .execSync(
      `docker ps --filter "label=devcontainer.config_file=${workspaceDevcontainerJson}" --filter "status=running" --format '{{.ID}}'`,
      { encoding: "utf-8" },
    )
    ?.trim()
    ?.split("\n")?.[0];
  if (existingRunningContainerID) {
    console.log(
      `Using existing running container ${existingRunningContainerID}`,
    );
    containerId = existingRunningContainerID;
    stopAfter = false;
  } else {
    const existingStoppedContainerID = cp
      .execSync(
        `docker ps -a --filter "label=devcontainer.config_file=${workspaceDevcontainerJson}" --filter "exited=0" --format '{{.ID}}'`,
        { encoding: "utf-8" },
      )
      ?.trim();
    if (
      existingStoppedContainerID &&
      existingStoppedContainerID.split("\n").length === 1
    ) {
      console.log(
        `Starting existing stopped container ${existingStoppedContainerID}`,
      );
      cp.execSync(`docker start ${existingStoppedContainerID}`);
      containerId = existingStoppedContainerID;
    } else {
      const existingContainerIDs = cp
        .execSync(
          `docker ps -a --filter "label=devcontainer.config_file=${workspaceDevcontainerJson}" --format '{{.ID}}'`,
          { encoding: "utf-8" },
        )
        ?.trim();
      existingContainerIDs
        .split("\n")
        .filter(Boolean)
        .forEach((id) => {
          console.log(`Removing existing container ${id}`);
          cp.execSync(`docker rm -f ${id}`);
        });
    }
  }

  // start container if not found
  if (!containerId) {
    const commandLine = `devcontainer up --workspace-folder ${project}`;
    const output = cp.execSync(commandLine, {
      stdio: ["ignore", "pipe", "inherit"],
      encoding: "utf-8",
    });
    const json = JSON.parse(output);
    if (json?.outcome !== "success") {
      throw new Error("Failed to start devcontainer");
    }
    containerId = json?.containerId;
  }

  // get workspace mount of container
  const workspaceMounts = JSON.parse(
    cp.execSync(
      `docker inspect --type container ${containerId} --format '{{json .Mounts}}'`,
    ),
  );
  const workspaceMount = workspaceMounts.find(
    (m) => m.Type === "bind" && m.Source.startsWith(projectRoot),
  );
  if (!workspaceMount) {
    throw new Error("Failed to find workspace mount");
  }
  const workspaceFolder = path.join(workspaceMount.Destination, project);

  // run command in container
  const result = cp.spawnSync(
    "docker",
    ["exec", "--workdir", workspaceFolder, containerId, ...runCommand],
    { stdio: "inherit", encoding: "utf-8" },
  );

  if (result.status !== 0) {
    console.error(`Command failed with exit code ${result.status}`);
    process.exit(result.status);
  }
} finally {
  if (containerId && stopAfter) {
    console.log(`Stopping container ${containerId}`);
    cp.execSync(`docker stop ${containerId}`);
  } else {
    console.log(`Leaving container ${containerId} running`);
  }
}
