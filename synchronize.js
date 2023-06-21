const fs = require("fs");
const cp = require("child_process");
const path = require("path");

if (!process.env._?.endsWith("/git") && !process.env._?.includes(".vscode")) {
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

cp.execSync("node generate-docker-compose.js", {
  cwd: __dirname,
  stdio: "inherit",
});
