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

function getServicePort(project) {
  const projectConfig = getProjectConfig(project);
  if (projectConfig.devcontainer.ports === undefined) {
    throw new Error(`No ports found for ${project}`);
  } else if (projectConfig.devcontainer.ports.length !== 1) {
    throw new Error(
      `Expected 1 port for ${project}, found ${projectConfig.devcontainer.ports.length}`,
    );
  }
  const port = projectConfig.devcontainer.ports[0];
  return port;
}

function writeTraefikConfig(projects, configPath) {
  const combinedConfig = projects.reduce(
    (acc, project) => {
      console.log(`found project ${project}`);
      const projectConfig = getProjectConfig(project);
      const config = projectConfig.traefik?.labels?.http;

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
              url: `http://${project}:${getServicePort(project)}`,
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

const categorizedProjects = availableProjects.reduce((acc, project) => {
  const projectConfig = getProjectConfig(project);
  if (projectConfig.category) {
    if (acc[projectConfig.category] === undefined) {
      acc[projectConfig.category] = [];
    }
    acc[projectConfig.category].push(project);
  } else if (project.endsWith("-test")) {
    if (acc.test === undefined) {
      acc.test = [];
    }
    acc.test.push(project);
  } else {
    console.warn(`No category found for ${project}`);
  }
  return acc;
}, {});

console.log("Available projects:");
Object.keys(categorizedProjects)
  .sort()
  .forEach((category) => {
    console.log(
      `  ${category}: ${categorizedProjects[category].sort().join(", ")}`,
    );
  });

const availableDeployProjects = [
  ...categorizedProjects.backend,
  ...categorizedProjects.api,
  ...categorizedProjects.frontend,
];
if (DEV) {
  availableDeployProjects.push(...categorizedProjects.development);
}

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

const frontendPort = process.env.FRONTEND_PORT || 80;

const traefik = {
  image: "traefik:v3.0",
  container_name: "traefik",
  command: [
    "--entrypoints.web.address=:80",
    "--entrypoints.rest-internal.address=:3000",
  ],
  ports: [`${frontendPort}:80`],
  volumes: [],
  networks: ["intranet"],
};

if (PROD) {
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
  } else if (
    BACKEND &&
    !["backend", "api"].some((cat) =>
      categorizedProjects[cat].includes(project),
    )
  ) {
    return;
  }

  const projectConfig = getProjectConfig(project);

  const service = {
    build: {
      context: devProjects.includes(project)
        ? `${project}/.devcontainer`
        : project,
    },
    container_name: project,
    networks: ["intranet"],
  };

  if (!devProjects.includes(project)) {
    service.image = `ghcr.io/dhhyi/recipe-db-${project}:latest`;
    if (!service.build.labels) {
      service.build.labels = {};
    }
    const packageJson = JSON.parse(
      fs.readFileSync(path.join(projectRoot, "package.json"), "utf8"),
    );

    if (
      typeof packageJson.repository === "string" &&
      packageJson.repository.startsWith("github:")
    ) {
      const repo = packageJson.repository.replace(
        /^github:/,
        "https://github.com/",
      );
      service.build.labels["org.opencontainers.image.source"] = repo;
    }
  }

  const appendEnvironment = (obj) => {
    if (!service.environment) {
      service.environment = {};
    }
    service.environment = { ...service.environment, ...obj };
  };

  if (devProjects.includes(project)) {
    service.volumes = [`./${project}:/app`];
  }

  if (DEV && projectConfig.traefik?.labels) {
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

  // if (projectConfig.category) {
  //   if (!service.profiles) {
  //     service.profiles = [];
  //   }
  //   service.profiles.push(projectConfig.category);
  // }

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

  if (PROD && categorizedProjects.backend.includes(project)) {
    if (!service.volumes) {
      service.volumes = [];
    }
    service.volumes.push("data:/app/data");
    service.environment.DATA_LOCATION = "/app/data/" + project;
  }

  if (PROD && projectConfig.extends?.includes("javascript")) {
    appendEnvironment({ NODE_ENV: "production" });
  }

  const findServicesExcluding = (projects, exclude) =>
    projects.filter((service) => !exclude.includes(service));

  const dependsOn = (services) =>
    services.reduce((acc, val) => {
      acc[val] = {
        condition: "service_started",
      };
      return acc;
    }, {});

  if (PROD && categorizedProjects.frontend.includes(project)) {
    service.depends_on = dependsOn(categorizedProjects.api);
  }

  if (PROD && categorizedProjects.api.includes(project)) {
    service.depends_on = dependsOn(["traefik", ...categorizedProjects.backend]);
  }

  if (DEV && categorizedProjects.development.includes(project)) {
    service.depends_on = dependsOn(
      findServicesExcluding(availableDeployProjects, [
        project,
        ...categorizedProjects.development,
      ]),
    );
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
