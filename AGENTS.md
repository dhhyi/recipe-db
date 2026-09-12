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
pnpm in-devcontainer graphql pnpm install
```

An optional `--rm` flag, placed before the project name, tears down the container after the command
runs instead of just stopping it (or leaving it running if it was already running). Use this to make
sure a devcontainer is rebuilt from scratch on the next run, e.g. after changing its `.project.yaml`
or Dockerfile:

```sh
pnpm in-devcontainer --rm recipes <command>
```

To tear down an already running container without running anything meaningful, use the `true`
executable as the command:

```sh
pnpm in-devcontainer --rm recipes true
```

## Modifying .project.yaml files

When modifying `.project.yaml` files, run `pnpm synchronize` to apply the changes. Do not modify files in .devcontainer directories directly.

### Peacock color palette

Each project's `.project.yaml` sets `peacock.remoteColor` (a pastel HSL color, S=50%, L=72%, except
`-test` projects which use L=57.6%, i.e. 20% darker than their base project) so devcontainer windows
are visually distinguishable. Hues are picked from a 15°-step wheel (0°, 15°, 30°, ... 345°):

- Frontend projects (`design`, `frontend`, `images-edit`, `recipes-edit`) use the 4 cardinal hues
  (0°, 90°, 180°, 270°) for maximum separation from each other.
- All other non-`-test` projects use one of: 30°, 60°, 120°, 150°, 210°, 240°, 300°, 330°.
- A `-test` project reuses its base project's hue, darkened by 20% lightness.
- The remaining hues (15°, 45°, 75°, 105°, 135°, 165°, 195°, 225°, 255°, 285°, 315°, 345°) are free —
  assign one of these to a new non-frontend project (or a new cardinal hue if adding a 5th frontend
  project) rather than picking an arbitrary color.

## Integration Testing projects

Before running tests, ensure the docker compose project is up and running.

Execute tests with the `package.json` script `in-devcontainer` and `test` target.

Examples:

```sh
pnpm in-devcontainer images-test test
```

This will run the `test:` script defined in the second yaml document of the project's `.project.yaml` file.

## Running precommit checks

Execute precommit checks with `in-devcontainer` script. (see above)
Make sure any existing devcontainer torn down before running precommit checks.

## REST API error responses

Every REST backend must report errors as [RFC 9457](https://www.rfc-editor.org/rfc/rfc9457) Problem
Details: `Content-Type: application/problem+json`, body `{ "type": "about:blank", "title", "status",
"detail", "code", "field"? }`. `code` is a stable, dash-cased machine-readable identifier
(`field` is set only for errors tied to a specific input field); `title`/`detail` are human-readable.
See [`recipes/lib/recipes/problem.ex`](recipes/lib/recipes/problem.ex) for the canonical
implementation. `graphql` forwards `code`/`field`/`status` from any backend's Problem Details response
into GraphQL error `extensions` generically (see `graphql/src/rest_client.rs`'s `RestError::into_error`),
so a new `code` automatically reaches GraphQL clients without any graphql-side change.
