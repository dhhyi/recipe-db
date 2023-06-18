const fs = require('fs');
const cp = require('child_process');

fs.readdirSync(__dirname).forEach(file => {
    if (fs.statSync(`${__dirname}/${file}`).isDirectory() && fs.existsSync(`${__dirname}/${file}/language.yaml`)) {
        console.log(`Synchronizing ${file}...`);
        cp.execSync('curl -so- https://raw.githubusercontent.com/dhhyi/devcontainer-creator/dist/bundle.js | node - language.yaml . --no-vscode', { cwd: `${__dirname}/${file}`, stdio: 'inherit' });
    }
})