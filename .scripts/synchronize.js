const fs = require("fs");
const cp = require("child_process");
const path = require("path");
const { globSync } = require("glob");
const { projectRoot, getAvailableProjects, languageFile } = require("./shared");

function searchForForbiddenFiles(availableProjects) {
  const forbiddenGitIgnores = globSync("**/.gitignore", {
    cwd: projectRoot,
  }).filter(
    (file) =>
      file !== ".gitignore" &&
      !availableProjects.some((project) => file === `${project}/.gitignore`)
  );
  if (forbiddenGitIgnores.length > 0) {
    console.error(
      `Forbidden .gitignore files found: ${forbiddenGitIgnores.join(", ")}`
    );
    process.exit(1);
  }

  const gitLsFiles = cp
    .execSync("git ls-files")
    .toString()
    .split("\n")
    .filter((file) => file !== "");
  const forbiddenPrettierIgnores = gitLsFiles.filter((file) =>
    /\/?\.prettierignore$/.test(file)
  );
  if (forbiddenPrettierIgnores.length > 0) {
    console.error(
      `Forbidden .prettierignore files found: ${forbiddenPrettierIgnores.join(
        ", "
      )}`
    );
    process.exit(1);
  }
}

function writePrettierIgnores(availableProjects) {
  const toDoProjects = availableProjects.filter((project) =>
    fs.existsSync(path.join(projectRoot, project, "pnpm-lock.yaml"))
  );

  const warning = `# This file is generated by synchronize.js. Do not edit it manually.\n\n`;
  const rootGitIgnore = fs.readFileSync(
    path.join(projectRoot, ".gitignore"),
    "utf8"
  );
  const extraIgnores = `
    # extra ignores
    pnpm-lock.yaml
  `.replace(/^ +/gm, "");

  const otherProjectsIgnores =
    "\n# extra runs\n" + toDoProjects.join("\n") + "\n";

  console.log(`Writing .prettierignore ...`);
  fs.writeFileSync(
    path.join(projectRoot, ".prettierignore"),
    warning + rootGitIgnore + extraIgnores + ".husky/_\n" + otherProjectsIgnores
  );

  toDoProjects.forEach((project) => {
    const localGitIgnore =
      "\n# local\n" +
      fs.readFileSync(path.join(projectRoot, project, ".gitignore"), "utf8");
    const outputFile = path.join(project, ".prettierignore");
    console.log(`Writing ${outputFile} ...`);
    fs.writeFileSync(
      path.join(projectRoot, outputFile),
      warning + rootGitIgnore + localGitIgnore + extraIgnores
    );
  });
}

function writeDccFiles(availableProjects) {
  availableProjects.forEach((project) => {
    console.log(`Writing Devcontainer in ${project} ...`);
    const commandLine = `curl -so- https://raw.githubusercontent.com/dhhyi/devcontainer-creator/dist/bundle.js | node - ${languageFile(
      project
    )} ${project} --no-vscode --dump-meta`;

    try {
      cp.execSync(commandLine, { cwd: projectRoot, encoding: "utf8" });
    } catch (e) {
      console.error(e.output?.join(""));
      console.error(e.message);
      process.exit(1);
    }
  });
}

function writeRootVSCodeSettingsFiles(availableProjects) {
  const vscodeSettings = {
    "files.exclude": availableProjects.reduce(
      (acc, project) => ({
        ...acc,
        [`${project}`]: true,
      }),
      {}
    ),
    "extensions.ignoreRecommendations": true,
  };
  console.log(`Writing .vscode/settings.json ...`);
  fs.mkdirSync(path.join(projectRoot, ".vscode"), { recursive: true });
  fs.writeFileSync(
    path.join(projectRoot, ".vscode/settings.json"),
    JSON.stringify(vscodeSettings, null, 2)
  );
}

const availableProjects = getAvailableProjects();

searchForForbiddenFiles(availableProjects);
writePrettierIgnores(availableProjects);
writeDccFiles(availableProjects);
writeRootVSCodeSettingsFiles(availableProjects);
