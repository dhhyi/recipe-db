const cp = require("child_process");
const fs = require("fs");

const project = process.argv[2];

if (!project) {
  console.error("Missing project name");
  process.exit(1);
} else if (!fs.existsSync(`project.${project}.language.yaml`)) {
  console.error(`project ${project} is missing`);
  process.exit(1);
} else if (!project.endsWith("-test")) {
  console.error(`project ${project} must end with -test`);
  process.exit(1);
}

let containerId = null;

try {
  const output = cp.execSync(`devcontainer up --workspace-folder ${project}`, {
    stdio: ["ignore", "pipe", "inherit"],
    encoding: "utf-8",
  });
  const json = JSON.parse(output);
  if (json?.outcome !== "success") {
    throw new Error("Failed to start devcontainer");
  }

  containerId = json?.containerId;

  cp.execSync(`devcontainer exec --workspace-folder ${project} /test.sh`, {
    stdio: "inherit",
    encoding: "utf-8",
  });
} finally {
  if (containerId) {
    cp.execSync(`docker rm -f ${containerId}`);
  }
}
