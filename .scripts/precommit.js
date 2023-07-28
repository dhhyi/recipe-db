const { globSync } = require("glob");
const cp = require("child_process");
const path = require("path");
const fs = require("fs");
const {
  getAvailableProjects,
  projectRoot,
  scriptRoot,
  getProjectConfig,
} = require("./shared");

const tasks = [];

const args = process.argv.slice(2);
const defaultRun = args.some((a) => a.includes("all"));
const verbose = args.some((a) => a.includes("verbose")) || args.includes("-v");

// generate merged schema
tasks.push({
  execDir: ".",
  command: "node .scripts/merge-graphql-schemas.js",
  dependent: globSync("*/.needs-graphql-schema").map((dir) =>
    path.dirname(dir),
  ),
  message: "Running 'merge-graphql-schemas'",
  container: false,
  priority: 100,
  run: defaultRun,
});

// create intranet network
tasks.push({
  execDir: ".",
  command: "node .scripts/create-intranet.js",
  dependent: getAvailableProjects(),
  message: "Checking intranet network",
  container: false,
  priority: 100,
  run: defaultRun,
});

// create intranet network
tasks.push({
  execDir: ".",
  command: "node .scripts/check-npm-dependency-sync.js",
  dependent: ["pnpm-lock.yaml", "package.json"],
  message: "Checking npm dependency synchronization",
  container: false,
  priority: 80,
  run: defaultRun,
});

// add prettier tasks
globSync("**/.prettierignore")
  .map((file) => path.dirname(file))
  .forEach((dir) => {
    const container =
      dir !== "." && getProjectConfig(dir).prettier?.plugins?.length > 0;

    tasks.push({
      execDir: dir,
      dependent: [dir],
      command: "npx prettier --write '**'",
      message: "Running 'prettier' in " + dir,
      container,
      priority: dir === "." ? 1 : 2,
      run: defaultRun,
    });
  });

// add eslint task for root scripts
tasks.push({
  execDir: path.basename(scriptRoot),
  dependent: [path.basename(scriptRoot)],
  command: "npx eslint --fix " + scriptRoot,
  message: "Running 'eslint' in " + path.basename(scriptRoot),
  container: false,
  priority: 5,
  run: defaultRun,
});

// calculate pre-commit in devcontainers
getAvailableProjects().forEach((dir) => {
  if (getProjectConfig(dir).precommit) {
    tasks.push({
      execDir: dir,
      dependent: [dir],
      command: "precommit",
      message: "Running 'precommit' in " + dir,
      container: true,
      priority: 10,
      run: defaultRun,
    });
  }
});

tasks.sort((a, b) => {
  if (a.priority === b.priority) {
    return a.execDir.localeCompare(b.execDir);
  }
  return b.priority - a.priority;
});

console.log(`Found ${tasks.length} tasks`);

const stagedFiles = cp
  .execSync("git diff --cached --name-only", { encoding: "utf8" })
  .split("\n")
  .filter((file) => file.length > 0);

tasks.forEach((task) => {
  if (task.dependent.some((dir) => dir === ".") && stagedFiles.length > 0) {
    task.run = true;
  } else if (
    stagedFiles.some((file) =>
      task.dependent.some(
        (dir) => file.startsWith(dir + "/") || file.endsWith(dir),
      ),
    )
  ) {
    task.run = true;
  }
});

console.log(`Running ${tasks.filter((task) => task.run).length} tasks`);

// run tasks with run = true
tasks
  .filter((task) => task.run)
  .forEach((task) => {
    console.log(task.message + (task.container ? " (devcontainer)" : ""));
    const stdio = verbose ? "inherit" : "pipe";

    try {
      if (task.container) {
        const commandLine = `node ${scriptRoot}/run-in-devcontainer.js ${task.execDir} ${task.command}`;
        cp.execSync(commandLine, { stdio });
      } else {
        cp.execSync(`${task.command}`, { cwd: task.execDir, stdio });
      }
    } catch (error) {
      if (!verbose) {
        const logPath = path.join(projectRoot, "precommit.log");
        fs.writeFileSync(logPath, error.output.join(""));
        cp.execSync(`less ${logPath}`, { stdio: "inherit" });
      }
      process.exit(1);
    }
  });

const changedFiles = cp
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
