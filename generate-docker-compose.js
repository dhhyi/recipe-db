const fs = require("fs");
const cp = require("child_process");
const path = require("path");

const production = process.argv.slice(2).some((arg) => arg.includes("prod"));

if (production) {
  console.log("Setting up for production...");
} else {
  console.log("Setting up for development...");
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

if (production) {
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

const regex = /^project\.([\w-]+)\.language\.yaml$/;

fs.readdirSync(__dirname).forEach((file) => {
  if (regex.test(file)) {
    const project = regex.exec(file)[1];
    console.log(`Synchronizing ${project}...`);
    cp.execSync(
      `curl -so- https://raw.githubusercontent.com/dhhyi/devcontainer-creator/dist/bundle.js | node - ${file} ${project} --no-vscode`,
      { cwd: __dirname, stdio: "inherit" }
    );

    if (project.endsWith("-test")) {
      return;
    }

    const service = {
      build: project,
      container_name: project,
      volumes: [`./${project}:/app`],
      labels: [],
      networks: ["intranet"],
      tty: true,
    };

    const languageYaml = yaml.load(
      fs.readFileSync(path.join(__dirname, file), "utf-8")
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
      service.environment = languageYaml.devcontainer.environment;
    }

    switch (project) {
      case "apollo":
        if (production) {
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
  }
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
