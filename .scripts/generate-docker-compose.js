const fs = require("fs");
const cp = require("child_process");
const path = require("path");
const {
  getAvailableProjects,
  projectRoot,
  scriptRoot,
  getProjectConfig,
} = require("./shared");

const availableProjects = getAvailableProjects();

const PROD = process.argv.slice(2).some((arg) => arg.includes("prod"));
const DEV = !PROD;

const availableDeployProjects = availableProjects.filter(
  (project) => !project.endsWith("-test") && (DEV || project !== "demo-data")
);

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
  devProjects.push("demo-data");

  if (requestedDevProjects.length > 0) {
    console.log(
      `Setting up VSCode attaching for ${requestedDevProjects.join(", ")}...`
    );
  }
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
  if (!availableDeployProjects.includes(project)) {
    return;
  }

  const service = {
    build: devProjects.includes(project) ? `${project}/.devcontainer` : project,
    container_name: project,
    networks: ["intranet"],
    tty: true,
  };

  const appendEnvironment = (obj) => {
    if (!service.environment) {
      service.environment = {};
    }
    service.environment = { ...service.environment, ...obj };
  };

  if (devProjects.includes(project)) {
    service.volumes = [`./${project}:/app`];
  }

  const projectConfig = getProjectConfig(project);
  if (projectConfig.traefik?.labels) {
    if (!service.labels) {
      service.labels = [];
    }

    service.labels.push("traefik.enable=true");

    const flattened = flattenObject(projectConfig.traefik.labels);
    service.labels.push(
      ...flattened
        .map(([k, v]) => `${k}=${v}`)
        .map((s) => (s.startsWith("traefik.") ? s : "traefik." + s))
    );
  }
  if (projectConfig.devcontainer?.environment) {
    appendEnvironment(projectConfig.devcontainer.environment);
  }

  if (devProjects.includes(project)) {
    // add container env from meta for VSCode container attach
    const devcontainerMetaPath = path.join(
      projectRoot,
      project,
      ".devcontainer_meta.json"
    );
    const devcontainerDockerfilePath = path.join(
      projectRoot,
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
        appendEnvironment(containerEnv);
      }
    }
  }

  if (DEV) {
    appendEnvironment({ TESTING: "true" });
  } else if (PROD) {
    appendEnvironment({ TESTING: null });
  }

  switch (project) {
    case "frontend":
      if (PROD) {
        appendEnvironment({ NODE_ENV: "production" });
      }
      service.depends_on = {
        apollo: {
          condition: "service_started",
        },
      };
      service.init = true;
      break;
    case "apollo":
      if (PROD) {
        appendEnvironment({ NODE_ENV: "production" });
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
    case "ratings":
      if (PROD) {
        if (!service.volumes) {
          service.volumes = [];
        }
        if (!fs.existsSync("./ratings/db.sqlite")) {
          cp.execSync("touch ./ratings/db.sqlite");
        }
        service.volumes.push("./ratings/db.sqlite:/app/db.sqlite");
      }
      break;
    case "recipes":
      if (PROD) {
        if (!service.volumes) {
          service.volumes = [];
        }
        if (!fs.existsSync("./recipes/db/data.db")) {
          cp.execSync("mkdir -p ./recipes/db");
          cp.execSync("touch ./recipes/db/data.db");
        }
        service.volumes.push("./recipes/db:/app/db");
      }
      break;
    case "demo-data":
      if (DEV) {
        service.entrypoint = "sh -Ec 'cd /app && sh -Ee generate.sh'";
        service.depends_on = {
          traefik: {
            condition: "service_started",
          },
          apollo: {
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

console.log("Writing docker-compose.yml ...");
fs.writeFileSync(
  path.join(projectRoot, "docker-compose.yml"),
  yaml.dump(dockerCompose, {
    quotingType: '"',
    forceQuotes: false,
    lineWidth: 1000,
  })
);

cp.execSync(`node ${path.join(scriptRoot, "create-intranet.js")}`, {
  stdio: "inherit",
});
