# Agent instructions

## README changes

Do not add new content to README.md files unless the user explicitly asks for it. Update existing content when changes make it outdated.

## GitHub issue planning

Use GitHub issues to plan and refine future work, not to track ad-hoc work performed in the current session.

- Create issues when the user asks to capture, plan, refine, or defer work for later implementation.
- Do not create an issue merely because the user requests an immediate fix, investigation, or code change. Handle that work directly in the session.
- When working on an existing issue, keep it and any relevant umbrella issue current. Do not create another issue for the same work.
- If you discover follow-up work outside the current scope, mention it; do not create an issue unless the user asks.

Apply the `spec` label to implementation-ready issues with settled scope, decisions, and acceptance criteria. Apply `idea` to work needing research, exploration, or further refinement. Research, exploration, and requirements-definition tasks remain `idea`, even when their research deliverables are clearly defined.

When asked to mark an issue as blocked by another issue, use GitHub's native issue dependency ("blocked by") feature rather than a label.

### Keeping umbrella issues current

Umbrella issues use the `umbrella` label and track larger outcomes through native sub-issues. Whenever a child issue changes, update its umbrella's main description in the same task to reflect current decisions, progress, open questions, and next steps rather than relying only on comments. Keep refinement distinct from implementation, link durable decision records, and close the umbrella only when its overall completion criteria are met.

Only issues labeled `umbrella` may have sub-issues. Attach sub-issues directly to the appropriate umbrella; do not nest them under ordinary issues. If a non-umbrella issue already has sub-issues, move those children to its umbrella.

Every umbrella issue must include a Mermaid `flowchart TD` showing implementation order and dependencies among its direct sub-issues. Use prerequisite-to-dependent arrows, matching native GitHub "blocked by" dependencies; clearly mark any cross-umbrella or non-blocking coordination separately rather than implying it is a native blocker. Update the diagram in the same task whenever sub-issues, their dependencies, or implementation order change. Prefer a flowchart over a Gantt chart because these plans express dependencies, not dates.

## Running commands for a project

Never run project tooling (elm, go, gradle, cargo, pnpm, ...) directly on the host. Always go through the devcontainer:

```sh
mise run --raw in-devcontainer <project> <command>
```

The command is executed with `fish` inside the project's devcontainer. An existing running container is reused and left running; a stopped container is restarted, or a new one is created if needed. Containers started by the script are stopped afterwards, even when the command fails. The command's exit status is returned to the caller, and its stdout is not mixed with lifecycle messages.

These command names are resolved from the second YAML document of the project's `.project.yaml`:

- `test` — runs the project's `test:` script
- `format` — runs the project's `format:` script
- `check` — runs the project's `check:` script

Examples:

```sh
mise run --raw in-devcontainer images-edit format
mise run --raw in-devcontainer graphql check
mise run --raw in-devcontainer recipes-test test
mise run --raw in-devcontainer images-edit pnpm build --output /dev/null
mise run --raw in-devcontainer graphql pnpm install
```

An optional `--rm` flag, placed before or after the project name, removes the container after the command runs instead of just stopping it (or leaving it running if it was already running). Use this to make sure a devcontainer is rebuilt from scratch on the next run, e.g. after changing its `.project.yaml` or Dockerfile:

```sh
mise run --raw in-devcontainer --rm recipes <command>
```

To tear down an already running container without running anything meaningful, use the `true` executable as the command:

```sh
mise run --raw in-devcontainer --rm recipes true
```

## Working on Bazel scripts

When working on Bazel scripts, run their checks, linting, and regression tests directly on the host from the repository root, not inside any project's devcontainer. This is an exception to the project-tooling and precommit-check rules. For example:

```sh
mise run test-scripts
mise exec -- bazelisk build --action_env=PATH --jobs=1 //:shellcheck //:test_scripts
```

Project generator, format, and check commands invoked by Bazel must still run in their respective devcontainers.

## Changing scripts or Bats tests

Whenever changing scripts or `.bats` files, run `mise run test-scripts` and `mise exec -- bazelisk build --action_env=PATH --jobs=1 //:shellcheck` from the repository root.

## Modifying .project.yaml files

When modifying `.project.yaml` files, run `mise run sync` to apply the changes. Do not modify files in .devcontainer directories directly.

### Peacock color palette

Each project's `.project.yaml` sets `peacock.remoteColor` (a pastel HSL color, S=50%, L=72%, except `-test` projects which use L=57.6%, i.e. 20% darker than their base project) so devcontainer windows are visually distinguishable. Hues are picked from a 15°-step wheel (0°, 15°, 30°, ... 345°):

- Frontend projects (`design`, `browse`, `images-edit`, `recipes-edit`) use the 4 cardinal hues (0°, 90°, 180°, 270°) for maximum separation from each other.
- All other non-`-test` projects use one of: 30°, 60°, 120°, 150°, 210°, 240°, 300°, 330°.
- A `-test` project reuses its base project's hue, darkened by 20% lightness.
- The remaining hues (15°, 45°, 75°, 105°, 135°, 165°, 195°, 225°, 255°, 285°, 315°, 345°) are free — assign one of these to a new non-frontend project (or a new cardinal hue if adding a 5th frontend project) rather than picking an arbitrary color.

## Integration Testing projects

Before running tests, ensure the docker compose project is up and running.

Execute tests with the `mise run --raw in-devcontainer` task and `test` target.

Examples:

```sh
mise run --raw in-devcontainer images-test test
```

This will run the `test:` script defined in the second yaml document of the project's `.project.yaml` file.

## Running precommit checks

Execute precommit checks with `in-devcontainer` script. (see above) Make sure any existing devcontainer torn down before running precommit checks.

When the user explicitly asks to run the precommit script or hook (for example, `sh .git/hooks/pre-commit`) without specifying a container, run that command directly on the host without using a container.

## REST API error responses

Every REST backend must report errors as [RFC 9457](https://www.rfc-editor.org/rfc/rfc9457) Problem Details: `Content-Type: application/problem+json`, body `{ "type": "about:blank", "title", "status", "detail", "code", "field"? }`. `code` is a stable, dash-cased machine-readable identifier (`field` is set only for errors tied to a specific input field); `title`/`detail` are human-readable. See [`recipes/lib/recipes/problem.ex`](recipes/lib/recipes/problem.ex) for the canonical implementation. `graphql` forwards `code`/`field`/`status` from any backend's Problem Details response into GraphQL error `extensions` generically (see `graphql/src/rest_client.rs`'s `RestError::into_error`), so a new `code` automatically reaches GraphQL clients without any graphql-side change.

## Investigating CI errors

When you are asked to investigate CI errors, start by pulling the logs of the latest run via GitHub CLI.

## List of possible REST API testing frameworks

If you pick one for a new project, make sure to remove it from this list.

- https://github.com/martinmaher/jcache-chat-citrus
- https://citrusframework.org/citrus/reference/3.4.0/html/index.html#http-rest
- https://gettaurus.org/
- https://github.com/svanoort/pyresttest
- https://rest-assured.io/
