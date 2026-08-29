# Agent instructions

## Modifying .project.yaml files

When modifying `.project.yaml` files, run `pnpm synchronize` to apply the changes. Do not modify files in .devcontainer directories directly.

## Testing projects

Before running tests, ensure the docker compose project is up and running.

Execute tests with the `package.json` script `test-project`.
