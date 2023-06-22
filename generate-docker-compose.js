const fs = require("fs");
const cp = require("child_process");
const path = require("path");

const regex = /^project\.([\w-]+)\.language\.yaml$/;

function languageFile(project) {
  return `project.${project}.language.yaml`;
}

const availableProjects = fs
  .readdirSync(__dirname)
  .filter((file) => regex.test(file))
  .map((file) => regex.exec(file)[1]);
const availableDeployProjects = availableProjects.filter(
  (project) => !project.endsWith("-test")
);

const PROD = process.argv.slice(2).some((arg) => arg.includes("prod"));
const DEV = !PROD;

if (PROD) {
  console.log("Setting up for production...");
} else {
  console.log("Setting up for development...");
}

const devProjects = [];

if (DEV) {
  const args = process.argv.slice(2);
  const requestedDevProjects = availableDeployProjects.filter((project) =>
    args.includes(project)
  );
  devProjects.push(...requestedDevProjects);

  console.log(
    `Setting up VSCode attaching for ${requestedDevProjects.join(", ")}...`
  );
}

const yaml = require("js-yaml");

function flattenObject(obj) {
  const result = [];
  for (const [k, v] of Object.entries(obj)) {
    if (typeof v === "object" && v !== null) {
      for (const [kk, vv] of flattenObject(v)) {
        result.push([`${k}.${kk}`, vv]);
      }
    } else {
      result.push([k, String(v)]);
    }
  }
  return result;
}

const dockerCompose = {
  version: "3",

  services: {},

  networks: {
    intranet: {
      name: "intranet",
    },
  },
};

const traefik = {
  image: "traefik:v3.0",
  container_name: "traefik",
  command: [
    "--providers.docker=true",
    "--providers.docker.exposedbydefault=false",
    "--entrypoints.web.address=:80",
    "--entrypoints.rest-internal.address=:3000",
  ],
  ports: ["80:80"],
  volumes: ["/var/run/docker.sock:/var/run/docker.sock:ro"],
  networks: ["intranet"],
};

if (PROD) {
  traefik.depends_on = {
    apollo: {
      condition: "service_started",
    },
  };
} else {
  traefik.command.push(
    "--api.insecure=true"
    // "--log.level=DEBUG",
  );
  traefik.ports.push("3000:3000", "8080:8080");
}

dockerCompose.services.traefik = traefik;

availableProjects.forEach((project) => {
  console.log(`Synchronizing ${project}...`);
  let commandLine = `curl -so- https://raw.githubusercontent.com/dhhyi/devcontainer-creator/dist/bundle.js | node - ${languageFile(
    project
  )} ${project} --no-vscode`;

  if (devProjects.includes(project)) {
    commandLine += "  --dump-meta";
  }

  cp.execSync(commandLine, { cwd: __dirname, stdio: "inherit" });

  if (!availableDeployProjects.includes(project)) {
    return;
  }

  const service = {
    build: devProjects.includes(project) ? `${project}/.devcontainer` : project,
    container_name: project,
    labels: [],
    networks: ["intranet"],
    tty: true,
  };

  if (devProjects.includes(project)) {
    service.volumes = [`./${project}:/app`];
  }

  const languageYaml = yaml.load(
    fs.readFileSync(path.join(__dirname, languageFile(project)), "utf-8")
  );
  if (languageYaml.traefik?.labels) {
    service.labels.push("traefik.enable=true");

    const flattened = flattenObject(languageYaml.traefik.labels);
    service.labels.push(
      ...flattened
        .map(([k, v]) => `${k}=${v}`)
        .map((s) => (s.startsWith("traefik.") ? s : "traefik." + s))
    );
  }
  if (languageYaml.devcontainer?.environment) {
    if (!service.environment) {
      service.environment = {};
    }
    service.environment = {
      ...service.environment,
      ...languageYaml.devcontainer.environment,
    };
  }

  if (devProjects.includes(project)) {
    // add container env from meta for VSCode container attach
    const devcontainerMetaPath = path.join(
      __dirname,
      project,
      ".devcontainer_meta.json"
    );
    const devcontainerDockerfilePath = path.join(
      __dirname,
      project,
      ".devcontainer",
      "Dockerfile"
    );
    if (
      fs.existsSync(devcontainerMetaPath) &&
      fs.existsSync(devcontainerDockerfilePath)
    ) {
      const meta = JSON.parse(fs.readFileSync(devcontainerMetaPath, "utf-8"));
      const containerEnv = meta
        .map((elem) => elem.containerEnv)
        .reduce((acc, val) => {
          if (val) {
            return { ...acc, ...val };
          }
          return acc;
        }, {});
      if (Object.keys(containerEnv).length) {
        if (!service.environment) {
          service.environment = {};
        }
        service.environment = { ...service.environment, ...containerEnv };
      }
    }
  }

  if (DEV) {
    if (!service.environment) {
      service.environment = {};
    }
    service.environment.TESTING = "true";
  }

  switch (project) {
    case "apollo":
      if (PROD) {
        if (!service.environment) {
          service.environment = {};
        }
        service.environment.NODE_ENV = "production";
        service.depends_on = {
          recipes: {
            condition: "service_started",
          },
          ratings: {
            condition: "service_started",
          },
        };
      }
      break;
    default:
      break;
  }

  dockerCompose.services[project] = service;
});

console.log("Writing docker-compose.yml...");
fs.writeFileSync(
  __dirname + "/docker-compose.yml",
  yaml.dump(dockerCompose, {
    quotingType: '"',
    forceQuotes: false,
    lineWidth: 1000,
  })
);

try {
  cp.execSync("docker network inspect intranet", { stdio: "ignore" });
} catch (e) {
  console.log("Creating network intranet...");
  cp.execSync("docker network create intranet", { stdio: "inherit" });
}
