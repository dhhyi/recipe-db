const cp = require("child_process");

try {
  cp.execSync("docker network inspect intranet", { stdio: "ignore" });
} catch (e) {
  console.log("Creating network intranet...");
  cp.execSync("docker network create intranet", { stdio: "inherit" });
}
