const fs = require("fs");
const cp = require("child_process");
const path = require("path");
const {
  getAvailableProjects,
  projectRoot,
  scriptRoot,
  getProjectConfig,
  checkInstallDependencies,
} = require("./shared");

checkInstallDependencies();

function writeTraefikConfig(projects, configPath) {
  const combinedConfig = projects.reduce(
    (acc, project) => {
      console.log(`found project ${project}`);
      const projectConfig = getProjectConfig(project);
      const config = projectConfig.traefik?.labels?.http;
      if (projectConfig.devcontainer.ports === undefined) {
        throw new Error(`No ports found for ${project}`);
      } else if (projectConfig.devcontainer.ports.length !== 1) {
        throw new Error(
          `Expected 1 port for ${project}, found ${projectConfig.devcontainer.ports.length}`,
        );
      }
      const port = projectConfig.devcontainer.ports[0];

      if (config === undefined) {
        throw new Error(`No traefik config found for ${project}`);
      }
      const serviceName = `recipe-db-${project}`;
      Object.entries(config.routers).forEach(([routerName, routerConfig]) => {
        const config = {
          service: serviceName,
          rule: routerConfig.rule,
          entrypoints: routerConfig.entrypoints.split(","),
        };
        if (routerConfig.middlewares) {
          config.middlewares = routerConfig.middlewares.split(",");
        }
        if (acc.http.routers[routerName] !== undefined) {
          throw new Error(`Router ${routerName} already exists`);
        }
        acc.http.routers[routerName] = config;
      });
      if (config.middlewares) {
        Object.entries(config.middlewares).forEach(
          ([middlewareName, middlewareConfig]) => {
            if (acc.http.middlewares[middlewareName] !== undefined) {
              throw new Error(`Middleware ${middlewareName} already exists`);
            }
            acc.http.middlewares[middlewareName] = middlewareConfig;
          },
        );
      }

      acc.http.services[serviceName] = {
        loadBalancer: {
          servers: [
            {
              url: `http://${project}:${port}`,
            },
          ],
          healthCheck: {
            interval: "10s",
            timeout: "1s",
            path: "/health",
          },
        },
      };

      return acc;
    },
    { http: { routers: {}, middlewares: {}, services: {} } },
  );

  console.log(
    `Traefik config with ${
      Object.keys(combinedConfig.http.routers).length
    } routers, ${
      Object.keys(combinedConfig.http.middlewares).length
    } middlewares and ${
      Object.keys(combinedConfig.http.services).length
    } services`,
  );

  const yaml = require("js-yaml");

  const yamlStr = yaml.dump(combinedConfig);
  console.log(`Writing traefik config to ${configPath}`);
  fs.writeFileSync(configPath, yamlStr);
}

const dockerComposeTargetPath = path.join(projectRoot, "docker-compose.yml");
const args = process.argv.slice(2);

if (
  args.length === 1 &&
  args[0] === "prepare" &&
  fs.existsSync(dockerComposeTargetPath)
) {
  console.log("docker-compose.yml already exists, skipping generation");
  process.exit(0);
}

const availableProjects = getAvailableProjects();

const PROD = args.some((arg) => arg.includes("prod"));
const DEV = !PROD;
const BACKEND = args.some((arg) => arg === "backend");

if (PROD) {
  console.log("Setting up for production...");
} else {
  console.log("Setting up for development...");
}
if (BACKEND) {
  console.log("Setting up backend only...");
}

const availableDeployProjects = availableProjects.filter(
  (project) =>
    !project.endsWith("-test") &&
    (DEV || project !== "demo-data") &&
    (!BACKEND || project !== "frontend"),
);

let devProjects = [];

const traefikConfigPath = path.join(projectRoot, "traefik.yml");
if (DEV) {
  devProjects = availableDeployProjects.filter((project) =>
    args.includes(project),
  );
  if (devProjects.length > 0) {
    console.log(`Setting up VSCode attaching for ${devProjects.join(", ")}...`);
  }
  if (fs.existsSync(traefikConfigPath)) {
    fs.unlinkSync(traefikConfigPath);
  }
} else if (PROD) {
  writeTraefikConfig(availableDeployProjects, traefikConfigPath);
}

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
      external: true,
    },
  },
};

if (PROD) {
  dockerCompose.volumes = {
    data: {
      name: "recipe-db-data",
      // driver: "local",
      // driver_opts: {
      //   type: "none",
      //   device: projectRoot + "/data",
      //   o: "bind",
      // },
    },
  };
}

const traefik = {
  image: "traefik:v3.0",
  command: [
    "--entrypoints.web.address=:80",
    "--entrypoints.rest-internal.address=:3000",
  ],
  ports: ["80:80"],
  volumes: [],
  networks: ["intranet"],
};

if (PROD) {
  traefik.depends_on = {
    apollo: {
      condition: "service_started",
    },
  };
  traefik.command.push("--providers.file.filename=/traefik_config.yml");
  traefik.volumes.push("./traefik.yml:/traefik_config.yml:ro");
} else {
  traefik.command.push(
    "--api.insecure=true",
    "--providers.docker=true",
    "--providers.docker.exposedbydefault=false",
  );
  traefik.volumes.push("/var/run/docker.sock:/var/run/docker.sock:ro");
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
        .map((s) => (s.startsWith("traefik.") ? s : "traefik." + s)),
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
      ".devcontainer_meta.json",
    );
    const devcontainerDockerfilePath = path.join(
      projectRoot,
      project,
      ".devcontainer",
      "Dockerfile",
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

  const setDBVolume = () => {
    if (!service.volumes) {
      service.volumes = [];
    }
    service.volumes.push("data:/app/data");
    service.environment.DATA_LOCATION = "/app/data/" + project;
  };

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
    case "recipes-edit":
      service.depends_on = {
        apollo: {
          condition: "service_started",
        },
      };
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
    case "demo-data":
      if (DEV) {
        service.entrypoint =
          "sh -Ec 'cd /app && sleep 2 && sh -Ee generate.sh'";
        const services = availableDeployProjects.filter(
          (service) => service !== "demo-data",
        );
        services.push("traefik");
        service.depends_on = services.reduce((acc, val) => {
          acc[val] = {
            condition: "service_started",
          };
          return acc;
        }, {});
      }
      break;
    case "recipes":
    case "ratings":
    case "inspirations":
    case "image-inline":
    case "link-extract":
      if (PROD) {
        setDBVolume();
      }
      break;
    default:
      console.error(`Unknown project ${project} - please add it to the script`);
      process.exit(1);
  }

  dockerCompose.services[project] = service;
});

const yaml = require("js-yaml");

console.log("Writing docker-compose.yml ...");
fs.writeFileSync(
  dockerComposeTargetPath,
  yaml.dump(dockerCompose, {
    quotingType: '"',
    forceQuotes: false,
    lineWidth: 1000,
  }),
);

cp.execSync(`node ${path.join(scriptRoot, "create-intranet.js")}`, {
  stdio: "inherit",
});
