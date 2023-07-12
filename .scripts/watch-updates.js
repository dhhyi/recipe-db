const fs = require("fs");
const cp = require("child_process");
const path = require("path");
const { scriptRoot } = require("./shared");

cp.execSync("git ls-files", { encoding: "utf-8" })
  .split("\n")
  .filter(
    (file) =>
      file.endsWith(".gitignore") ||
      file.endsWith(".project.yaml") ||
      file.endsWith(".scripts/synchronize.js")
  )
  .forEach((file) => {
    console.log(`Watching ${file}`);
    fs.watchFile(file, () => {
      console.log(
        `-------------------------------------\nFile ${file} changed`
      );
      cp.execSync(`node ${scriptRoot}/synchronize.js --no-dcc`, {
        stdio: "inherit",
      });

      if (file.endsWith(".project.yaml")) {
        cp.execSync(`sh ${path.dirname(file)}/.update_devcontainer.sh`, {
          stdio: "inherit",
        });
      }
    });
  });
