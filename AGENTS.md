# Agent instructions

## Running commands for a project

Never run project tooling (elm, go, gradle, cargo, pnpm, ...) directly on the host. Always go through
the devcontainer:

```sh
pnpm in-devcontainer <project> <command>
```

The command is executed with `fish` inside the project's devcontainer. An existing running container
is reused, otherwise one is started (and stopped again afterwards).

Three command names are special and are not passed through verbatim — they are resolved from the
second yaml document of the project's `.project.yaml`:

- `test` — runs the project's `test:` script
- `precommit` — runs the project's `precommit:` script with `PRE_COMMIT=1` set
- `prettier` — runs `npx prettier --write '**'` (only for projects that declare a `prettier:` section)

Examples:

```sh
pnpm in-devcontainer images-edit precommit
pnpm in-devcontainer images-edit prettier
pnpm in-devcontainer recipes-test test
pnpm in-devcontainer images-edit pnpm build --output /dev/null
pnpm in-devcontainer apollo pnpm install
```

## Modifying .project.yaml files

When modifying `.project.yaml` files, run `pnpm synchronize` to apply the changes. Do not modify files in .devcontainer directories directly.

## Integration Testing projects

Before running tests, ensure the docker compose project is up and running.

Execute tests with the `package.json` script `test-project`.

Examples:

```sh
pnpm test-project images-test
```

## Running precommit checks

Execute precommit checks with `in-devcontainer` script. (see above)
Make sure any existing devcontainer torn down before running precommit checks.
