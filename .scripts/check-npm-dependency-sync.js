const fs = require("fs");
const path = require("path");
const { projectRoot, getAvailableProjects } = require("./shared");

const yaml = require("js-yaml");
const availableProjects = getAvailableProjects();

console.log("Checking pnpm-lock.yaml file synchronization ...");

const pnpmLockFiles = [
  path.join(projectRoot, "pnpm-lock.yaml"),
  ...availableProjects.map((project) =>
    path.join(projectRoot, project, "pnpm-lock.yaml"),
  ),
].filter((file) => fs.existsSync(file));

const dependencies = {};
const addDependencies = (file, section) => {
  Object.entries(section).forEach(([dependency, { version }]) => {
    if (!dependencies[dependency]) {
      dependencies[dependency] = [];
    }
    dependencies[dependency].push({
      version: version?.replace(/\(.*/, ""),
      file,
    });
  });
};

pnpmLockFiles.forEach((file) => {
  const lockfile = yaml.load(fs.readFileSync(file, "utf8"));
  addDependencies(file, lockfile.dependencies || {});
  addDependencies(file, lockfile.devDependencies || {});
});

let inSync = true;

Object.entries(dependencies).forEach(([dependency, versions]) => {
  if (versions.length > 1) {
    const first = versions[0];
    const rest = versions.slice(1);
    if (!rest.every(({ version }) => version === first.version)) {
      console.error(`Versions of ${dependency} are not in sync:`);
      console.error(`  ${first.file}: ${first.version}`);
      rest.forEach(({ file, version }) => {
        console.error(`  ${file}: ${version}`);
      });
      inSync = false;
    }
  }
});

if (!inSync) {
  console.error("pnpm-lock.yaml files are not in sync");
  process.exit(1);
}
