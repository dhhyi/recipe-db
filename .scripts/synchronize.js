const fs = require("fs");
const cp = require("child_process");
const path = require("path");
const prettier = require("prettier");
const { globSync } = require("glob");
const {
  projectRoot,
  getAvailableProjects,
  languageFile,
  getProjectConfig,
} = require("./shared");

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
  const forbiddenPrettierFiles = gitLsFiles.filter((file) =>
    /\/?(\.prettierignore|.*prettierrc.*|prettier\.config\..*)$/.test(file)
  );
  if (forbiddenPrettierFiles.length > 0) {
    console.error(
      `Forbidden files found: ${forbiddenPrettierFiles.join(", ")}`
    );
    process.exit(1);
  }
}

const warning = (commentSign) =>
  `${commentSign} This file is generated by synchronize.js. Do not edit it manually.\n\n`;

function writePrettierIgnores(availableProjects) {
  const rootGitIgnore = fs.readFileSync(
    path.join(projectRoot, ".gitignore"),
    "utf8"
  );
  const extraIgnores = `
    # extra ignores
    pnpm-lock.yaml
    .gitkeep
    .needs-graphql-schema
    *.txt
  `.replace(/^ +/gm, "");

  const otherProjectsIgnores =
    "\n# extra runs\n" + availableProjects.join("\n") + "\n";

  console.log(`Writing .prettierignore ...`);
  fs.writeFileSync(
    path.join(projectRoot, ".prettierignore"),
    warning("#") +
      rootGitIgnore +
      extraIgnores +
      ".husky/_\n" +
      otherProjectsIgnores
  );

  availableProjects.forEach((project) => {
    const localGitignorePath = path.join(projectRoot, project, ".gitignore");
    const localGitIgnore = fs.existsSync(localGitignorePath)
      ? "\n# local\n" + fs.readFileSync(localGitignorePath, "utf8")
      : "";

    const projectConfig = getProjectConfig(project);
    const extraLocalIgnores =
      (projectConfig.prettier?.ignore || []).join("\n") + "\n";

    const outputFile = path.join(project, ".prettierignore");
    console.log(`Writing ${outputFile} ...`);
    fs.writeFileSync(
      path.join(projectRoot, outputFile),
      warning("#") +
        rootGitIgnore +
        localGitIgnore +
        extraIgnores +
        extraLocalIgnores
    );
  });
}

function writePrettierConfigs(availableProjects) {
  const rootPrettierConfigPath = path.join(projectRoot, ".prettierrc.cjs");

  const prettierConfig = (plugins, overrides) => {
    const pluginsContent = `plugins: [${plugins
      .sort()
      .map((plugin) => `require.resolve("${plugin}")`)
      .join(", ")}],`;

    const overridesContent =
      overrides.length > 0
        ? `overrides: [${overrides
            .map(([files, options]) => JSON.stringify({ files, options }))
            .join(", ")}],`
        : "";

    const content =
      warning("//") +
      "module.exports = {" +
      pluginsContent +
      overridesContent +
      "}";

    return prettier.format(content, { parser: "flow" });
  };

  const rootPrettierPlugins = [
    "prettier-plugin-sh",
    "prettier-plugin-toml",
    "@prettier/plugin-xml",
  ];
  const sharedOverrides = [
    [
      ["*.svg"],
      {
        parser: "xml",
        xmlWhitespaceSensitivity: "ignore",
        xmlQuoteAttributes: "double",
        printWidth: 200,
      },
    ],
  ];

  const rootConfig = prettierConfig(rootPrettierPlugins, [
    [[".husky/*-*"], { parser: "sh" }],
    [["LICENSE"], { parser: "markdown" }],
    ...sharedOverrides,
  ]);

  console.log(`Writing .prettierrc.cjs ...`);
  fs.writeFileSync(rootPrettierConfigPath, rootConfig);

  availableProjects.forEach((project) => {
    console.log(`Writing ${project}/.prettierrc.cjs ...`);
    const config = getProjectConfig(project);
    const extraPlugins = config.prettier?.plugins || [];
    const plugins = [...rootPrettierPlugins, ...extraPlugins];

    const projectPrettierConfigPath = path.join(
      projectRoot,
      project,
      ".prettierrc.cjs"
    );
    const projectPrettierConfig = prettierConfig(plugins, sharedOverrides);

    fs.writeFileSync(projectPrettierConfigPath, projectPrettierConfig);
  });
}

function writeDockerIgnores(availableProjects) {
  const rootGitIgnore =
    fs
      .readFileSync(path.join(projectRoot, ".gitignore"), "utf8")
      .split("\n")
      .filter((line) => line !== "merged-schema.graphql")
      .join("\n") + "\n";

  const extras = `
    .project.yaml
    .gitignore
    *.md
  `.replace(/^ +/gm, "");

  availableProjects.forEach((project) => {
    if (fs.existsSync(path.join(projectRoot, project, "Dockerfile"))) {
      console.log(`Writing ${project}/.dockerignore ...`);

      const localGitIgnorePath = path.join(projectRoot, project, ".gitignore");
      const localGitIgnore = fs.existsSync(localGitIgnorePath)
        ? fs.readFileSync(localGitIgnorePath, "utf8") + "\n"
        : "";

      const localDockerIgnorePath = path.join(
        projectRoot,
        project,
        ".dockerignore"
      );
      const content = warning("#") + rootGitIgnore + localGitIgnore + extras;

      fs.writeFileSync(localDockerIgnorePath, content);
    }
  });
}

function writeDccFiles(availableProjects) {
  availableProjects.forEach((project) => {
    console.log(`Writing Devcontainer in ${project} ...`);
    const commandLine = `curl -so- https://raw.githubusercontent.com/dhhyi/devcontainer-creator/dist/bundle.js | node - ${languageFile(
      project
    )} ${project} --no-vscode --no-validate`;

    try {
      cp.execSync(commandLine, { cwd: projectRoot, encoding: "utf8" });
    } catch (e) {
      console.error(e.output?.join(""));
      console.error(e.message);
      process.exit(1);
    }
  });
}

function writeRootVSCodeSettingsFile(availableProjects) {
  const vscodeSettings = {
    "files.exclude": availableProjects.reduce(
      (acc, project) => ({
        ...acc,
        [`${project}/[!.]*`]: true,
      }),
      {}
    ),
    "extensions.ignoreRecommendations": true,
    "task.autoDetect": "off",
  };
  console.log(`Writing .vscode/settings.json ...`);
  fs.mkdirSync(path.join(projectRoot, ".vscode"), { recursive: true });
  fs.writeFileSync(
    path.join(projectRoot, ".vscode/settings.json"),
    JSON.stringify(vscodeSettings, null, 2)
  );
}

function writeRootVSCodeTasksFile() {
  const tasks = {
    tasks: [
      {
        label: "watch for changes",
        type: "shell",
        command: "node .scripts/watch-updates.js",
        problemMatcher: [],
      },
    ],
  };
  console.log(`Writing .vscode/tasks.json ...`);
  fs.mkdirSync(path.join(projectRoot, ".vscode"), { recursive: true });
  fs.writeFileSync(
    path.join(projectRoot, ".vscode/tasks.json"),
    JSON.stringify(tasks, null, 2)
  );
}

const availableProjects = getAvailableProjects();

searchForForbiddenFiles(availableProjects);
writePrettierIgnores(availableProjects);
writePrettierConfigs(availableProjects);
writeDockerIgnores(availableProjects);
if (!process.argv.slice(2).includes("--no-dcc")) {
  writeDccFiles(availableProjects);
}
writeRootVSCodeSettingsFile(availableProjects);
writeRootVSCodeTasksFile();
