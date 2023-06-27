const { globSync } = require("glob");
const cp = require("child_process");
const path = require("path");
const fs = require("fs");
const { getAvailableProjects, projectRoot, scriptRoot } = require("./shared");

const tasks = [];

const args = process.argv.slice(2);
const defaultRun = args.some((a) => a.includes("all"));
const verbose = args.some((a) => a.includes("verbose")) || args.includes("-v");

// add prettier tasks
globSync("**/.prettierignore")
  .map((file) => path.dirname(file))
  .forEach((dir) => {
    tasks.push({
      dir,
      command: "npx prettier --write .",
      message: "Running 'prettier' in " + dir,
      container: false,
      priority: dir === "." ? 1 : 2,
      run: defaultRun,
    });
  });

// calculate pre-commit in devcontainers
getAvailableProjects().forEach((dir) => {
  if (fs.existsSync(path.join(projectRoot, dir, "precommit.sh"))) {
    tasks.push({
      dir,
      command: "sh -e precommit.sh",
      message: "Running 'precommit.sh' in " + dir,
      container: true,
      priority: 3,
      run: defaultRun,
    });
  } else {
    const packageJsonPath = path.join(projectRoot, dir, "package.json");
    if (fs.existsSync(packageJsonPath)) {
      const packageJson = JSON.parse(
        fs.readFileSync(packageJsonPath, {
          encoding: "utf8",
        })
      );
      if (packageJson.scripts?.precommit) {
        tasks.push({
          dir,
          command: "npm run precommit",
          message: "Running 'npm run precommit' in " + dir,
          container: true,
          priority: 3,
          run: defaultRun,
        });
      }
    }
  }
});

tasks.sort((a, b) => {
  if (a.priority === b.priority) {
    return a.dir.localeCompare(b.dir);
  }
  return b.priority - a.priority;
});

console.log(`Found ${tasks.length} tasks`);

const stagedFiles = cp
  .execSync("git diff --cached --name-only", { encoding: "utf8" })
  .split("\n")
  .filter((file) => file.length > 0);

tasks.forEach((task) => {
  if (task.dir === "." && stagedFiles.length > 0) {
    task.run = true;
  } else if (stagedFiles.some((file) => file.startsWith(task.dir + "/"))) {
    task.run = true;
  }
});

console.log(`Running ${tasks.filter((task) => task.run).length} tasks`);

// run tasks with run = true
tasks
  .filter((task) => task.run)
  .forEach((task) => {
    console.log(task.message);
    const stdio = verbose ? "inherit" : "pipe";

    try {
      if (task.container) {
        const commandLine = `node ${scriptRoot}/run-in-devcontainer.js ${task.dir} ${task.command}`;
        cp.execSync(commandLine, { stdio });
      } else {
        cp.execSync(`${task.command}`, { cwd: task.dir, stdio });
      }
    } catch (error) {
      console.log(error.output?.join(""));
      console.error(error.message);
      process.exit(1);
    }
  });

changedFiles = cp
  .execSync("git diff --name-only", { encoding: "utf8" })
  .split("\n")
  .filter((file) => file.length > 0);

const changes = stagedFiles.filter((file) => changedFiles.includes(file));

if (changes.length > 0) {
  console.log(`Files were probably changed by precommit script:`);
  changes.forEach((file) => console.log(` - ${file}`));
  console.log("Aborting commit");
  process.exit(1);
}
