const fs = require("fs");
const cp = require("child_process");

const regex = /^project\.([\w-]+)\.language\.yaml$/;

fs.readdirSync(__dirname).forEach((file) => {
  if (regex.test(file)) {
    const project = regex.exec(file)[1];
    console.log(`Synchronizing ${project}...`);
    cp.execSync(
      `curl -so- https://raw.githubusercontent.com/dhhyi/devcontainer-creator/dist/bundle.js | node - ${file} ${project} --no-vscode`,
      { cwd: __dirname, stdio: "inherit" }
    );
  }
});
