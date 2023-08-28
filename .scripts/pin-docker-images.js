const fs = require("fs");
const cp = require("child_process");

const {
  projectRoot,
  getAvailableProjects,
  checkInstallDependencies,
} = require("./shared");

checkInstallDependencies();

const configPath = `${projectRoot}/.docker-images-lock.txt`;

function getImageSHA(image) {
  return cp
    .execSync(`docker inspect --format='{{index .RepoDigests 0}}' ${image}`)
    .toString()
    .trim()
    .split("@")[1];
}

function pullImage(image) {
  try {
    console.log(`Pulling ${image}`);
    cp.execSync(`docker pull ${image}`, { stdio: "pipe" });
  } catch (e) {
    console.error(e.message);
    process.exit(1);
  }
}

function tagImage(source, target) {
  try {
    console.log(`Tagging ${source} as ${target}`);
    cp.execSync(`docker tag ${source} ${target}`, { stdio: "pipe" });
  } catch (e) {
    console.error(e.message);
    process.exit(1);
  }
}

function getProjectImageNames() {
  const dockerFiles = getAvailableProjects()
    .map((project) => {
      const dockerfilePath = `${projectRoot}/${project}/Dockerfile`;
      return fs.existsSync(dockerfilePath) ? dockerfilePath : null;
    })
    .filter(Boolean);

  const images = dockerFiles
    .flatMap((dockerfilePath) => {
      const regex = /FROM\s+([^\s]+)/gm;
      const labelsRegex = /FROM.*\s+AS\s+([^\s]+)/gim;

      const dockerfile = fs.readFileSync(dockerfilePath, "utf8");

      let match;

      const images = [];
      while ((match = regex.exec(dockerfile)) !== null) {
        images.push(match[1]);
      }

      const labels = [];
      while ((match = labelsRegex.exec(dockerfile)) !== null) {
        labels.push(match[1]);
      }

      return images.filter((image) => !labels.includes(image));
    })
    .filter((image) => image !== "scratch")
    .filter((v, i, a) => a.indexOf(v) === i)
    .sort();

  return images;
}

function getLockfileImages() {
  const lockfile = fs.readFileSync(configPath, "utf8");
  return lockfile
    .split("\n")
    .filter(Boolean)
    .reduce((acc, line) => {
      const [image, sha] = line.split("@");
      acc[image] = sha;
      return acc;
    }, {});
}

if (process.argv.slice(2).includes("update")) {
  const imageShas =
    getProjectImageNames()
      .map((image) => {
        pullImage(image);
        const sha = getImageSHA(image);
        return `${image}@${sha}`;
      })
      .join("\n") + "\n";

  fs.writeFileSync(configPath, imageShas);
} else {
  const lockfileImages = getLockfileImages();
  const projectImages = getProjectImageNames();

  const inSync =
    Object.keys(lockfileImages).length === projectImages.length &&
    projectImages.every((image) => !!lockfileImages[image]);

  if (!inSync) {
    console.error(
      "Images are not in sync. Run `npm run pin-docker-images update` to update the lockfile.",
    );
    process.exit(1);
  }

  Object.entries(lockfileImages).forEach(([image, sha]) => {
    let [base, tag] = image.split(":");
    if (!tag) {
      tag = "latest";
    }

    try {
      const sha = getImageSHA(`${base}:${tag}`);
      if (sha === lockfileImages[image]) {
        console.log(`${base}:${tag} is already up to date`);
        return;
      }
    } catch (e) {
      // ignore
    }

    pullImage(`${base}@${sha}`);
    tagImage(`${base}@${sha}`, `${base}:${tag}`);
  });
}
