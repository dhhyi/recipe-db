const fs = require("fs");
const cp = require("child_process");
const path = require("path");

if (!process.env._?.endsWith("/git")) {
  cp.execSync("npm exec pnpm install", { cwd: __dirname, stdio: "inherit" });

  fs.readdirSync(__dirname).forEach((file) => {
    if (
      fs.statSync(path.join(__dirname, file)).isDirectory() &&
      fs.existsSync(path.join(__dirname, file, "pnpm-lock.yaml"))
    ) {
      console.log(`Installing dependencies in ${file}...`);
      cp.execSync("npm exec pnpm install", {
        cwd: path.join(__dirname, file),
        stdio: "inherit",
      });
    }
  });
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

dockerCompose.services.traefik = {
  image: "traefik:v3.0",
  container_name: "traefik",
  command: [
    // "--log.level=DEBUG",
    "--api.insecure=true",
    "--providers.docker=true",
    "--providers.docker.exposedbydefault=false",
    "--entrypoints.web.address=:80",
    "--entrypoints.rest-internal.address=:3000",
  ],
  ports: ["80:80", "8080:8080"],
  volumes: ["/var/run/docker.sock:/var/run/docker.sock:ro"],
  networks: ["intranet"],
};

const regex = /^project\.([\w-]+)\.language\.yaml$/;

fs.readdirSync(__dirname).forEach((file) => {
  if (regex.test(file)) {
    const project = regex.exec(file)[1];
    console.log(`Synchronizing ${project}...`);
    cp.execSync(
      `curl -so- https://raw.githubusercontent.com/dhhyi/devcontainer-creator/dist/bundle.js | node - ${file} ${project} --no-vscode`,
      { cwd: __dirname, stdio: "inherit" }
    );

    const service = {
      build: project,
      volumes: [`./${project}:/app`],
      labels: [],
      networks: ["intranet"],
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
