# Agent instructions

## README changes

Do not add new content to README.md files unless the user explicitly asks for it. Update existing content when changes make it outdated.

## Documentation

Follow the [documentation guidelines in CONTRIBUTING.md](CONTRIBUTING.md#documentation) when writing or revising documentation.

## Local demo Compose cluster

- The local development/demo Docker Compose project is disposable: agents may independently reset, destroy, and [reseed its demo data](demo-data/README.md), which can be reconstructed.
- Agents may independently change its credential-free default role to `anonymous`, `member`, or `owner`; see [local identity configuration](docs/browser-authentication.md#local-credential-free-and-token-identities).
- Verify the target is the intended local demo Compose project before acting; avoid affecting other users or unrelated data. This permission excludes production, shared, and other environments. Preserve secrets and do not weaken production defaults.

## Dependency coverage for new projects

When adding a project or dependency manifest, update [.github/dependabot.yml](.github/dependabot.yml) in the same change for every source supported by Dependabot security updates. Preserve the security-only policy (`open-pull-requests-limit: 0`). If introducing another supported ecosystem or manifest layout, extend discovery and Bazel inputs for [.scripts/tests/dependabot.bats](.scripts/tests/dependabot.bats) so future omissions fail CI. For unsupported sources, document the coverage gap in [CONTRIBUTING.md](CONTRIBUTING.md#dependency-security-updates); do not claim they are scanned or enable routine version updates without approval.

Verify coverage with `mise run test-scripts .scripts/tests/dependabot.bats`. The suite also runs in pre-commit and CI.

## GraphQL access boundary

All normal client data operations go through GraphQL via trusted ingress. Do not introduce direct client-to-backend access. Backend maintenance APIs must remain private and be available only in backup mode. Testing-only data-reset APIs are a separate private interface, available only in testing mode, not backup mode. Public static/image delivery is an intentional exception.

Every API/backend project must declare a `backupRole` in its `.project.yaml`. Services classified as an authoritative source or cleanup participant must implement the versioned private maintenance API described in [the production Kubernetes operations guide](docs/production-kubernetes.md). Do not expose maintenance or test-reset routes through ingress, GraphQL, or MCP.

When developing or changing a service, follow the [backup-participant checklist](docs/production-kubernetes.md#backup-participant-development-checklist).

## GitHub issue planning

Follow [issue planning and refinement](CONTRIBUTING.md#issue-planning-and-refinement) and [completion rules](CONTRIBUTING.md#hierarchy-dependencies-and-completion).

- Propose refinement changes and wait for confirmation before modifying issues. Plan approval does not authorize implementation; documentation edits count as implementation.
- Keep PR-backed issues open until merge; use a closing keyword in the PR. Report pending review accurately in umbrellas and dependencies.
- Create future-work issues only when asked; reuse existing issues and preserve their agreed scope and discussion.

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

When instructed to create a Git worktree, run `mise install` from the new worktree root immediately after creating it, before running other project commands. If setup does not generate `.prettierignore`, run `mise run sync-ignore-files` before invoking Prettier or the pre-commit hook.

## Working on Bazel scripts

When running checks, linting, or regression tests for Bazel scripts, run them directly on the host from the repository root, not inside any project's devcontainer. This is an exception to the project-tooling and precommit-check rules.

For a single topic group, use `mise run test-scripts <group>` or `mise run --raw bazel build --action_env=PATH --jobs=1 //:test_scripts_<group>`. For one suite, use `mise run test-scripts .scripts/tests/<suite>.bats` or build `//:test_scripts_suite_<suite>`. Use the `bazel` Mise task for direct Bazel commands, as the hook and CI do: it constructs PATH from Mise-managed tool directories, the Mise executable's directory and fixed system directories (`/usr/local/bin:/usr/bin:/bin`), excluding caller-specific Git/VS Code paths. Keep `--action_env=PATH` on builds so tool-path changes still invalidate actions. Groups and each suite's explicit inputs are defined in `.scripts/tests/groups.yaml`: `compose`, `release`, `deploy`, `backup`, `restore`, `tasks`, `workflows`, `precommit`, `freshness`, `devcontainer`, `formatting`, and `tooling`. Each suite has an independent Bazel cache action; group targets aggregate their suites. Assign every new Bats suite to exactly one group and list its inputs; generation rejects unassigned suites and patterns matching no files.

Project generator, format, and check commands invoked by Bazel must still run in their respective devcontainers.

## Committing during autonomous implementation

Unless the user asks to leave changes uncommitted, commit each self-contained implementation step before moving to the next instead of waiting until the whole task is done. Sessions can time out and lose uncommitted work.

The pre-commit hook runs ShellCheck and applicable project formatting/checks, but no script regression tests. CI builds all Bazel targets, including every script regression suite. Do not manually duplicate the hook's checks before committing.

Whenever changing code or scripts, run the smallest relevant tests that verify the changed behavior and preserve existing behavior, even when a commit will be made. Prefer a single script-test suite or focused project test selector; use a topic group only when the change spans multiple suites. Use the commands above for script tests and the project's devcontainer for project tests. Leave exhaustive tests to CI; run broader checks locally only when explicitly requested or needed to diagnose a failure.

The pre-commit hook may apply formatting fixes and then abort the commit with `Files were probably changed by precommit script`. In that case, review the changes, stage the affected files again with `git add`, and repeat the commit.

### Cloud-agent checkpoints

For GitHub Actions-backed Copilot cloud agents, configure the repository's Agents variable `RECIPE_DB_SKIP_PRECOMMIT=1`. GitHub exposes it to the agent's commands; the pre-commit script logs the bypass and returns without running checks. Unset, empty, and other values preserve normal checks. Do not set this variable yourself to bypass checks in other environments.

When `RECIPE_DB_SKIP_PRECOMMIT=1` is already configured, and the user has not asked to leave changes uncommitted:

- Commit and publish the first meaningful implementation change before starting expensive validation. Use ordinary commits; `--no-verify` is unnecessary.
- Commit and publish each coherent implementation step before moving to another step. Use the environment's supported publishing mechanism; local commits alone are not a durable checkpoint.
- Preserve useful partial work even when tests fail. Identify known failures or pending validation in checkpoint messages; do not describe checkpoints as verified.
- Run targeted tests during development; leave exhaustive checks to CI rather than manually running the skipped hook.
- Before ending the session, commit and publish remaining useful changes and report unfinished work and validation.

CI checks remain required before merging. The Publish workflow skips validation while the PR title contains `[WIP]`; remove that marker when requesting CI feedback.

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

## Runtime modes and REST API test resets

The supported runtime modes are `production`, `testing`, and `backup`. An absent `MODE` defaults to `production`; testing and backup require explicit selection, and empty or unknown values fail startup. Remove obsolete runtime reads and managed configuration.

Every REST API that owns stored data must provide a private delete-all-data API for isolated testing as `DELETE` on its root collection resource (for example, `DELETE /recipes` or `DELETE /images`, not the server root `/` or a separate `/reset` endpoint), available only with explicit `MODE=testing`. Preserve supported trailing-slash variants; stateless APIs do not need a meaningless reset endpoint. Clear all service-owned test data, not configuration, credentials, other services' storage, or backups. Production (including unset `MODE`) and backup mode must not expose or execute these resets; cover supported route variants and verify denied requests leave data unchanged. Do not expose resets through public ingress, GraphQL, or MCP.

## Service shutdown

Every service container (including shell wrappers and sidecars) must exit 0 within seconds of SIGTERM and any image `STOPSIGNAL` override (for example, nginx's SIGQUIT). Containers run the service as PID 1, where the kernel ignores signals without an installed handler, so install one explicitly (or `trap` the required signals in shell commands). Test shutdown in the built container, not only a host subprocess. Backup capture refuses Pods that were SIGKILLed (exit 137); the 120-second termination grace is only an upper bound, not a substitute for clean exit.

## REST API health endpoints

Every REST backend must provide a non-mutating `GET /health` endpoint in every supported runtime mode. Keep it reachable by internal health probes without exposing sensitive information or requiring public ingress access. Preserve existing response contracts; recipes, images, ratings and inspirations currently return `204 No Content` when healthy. Distinguish liveness from readiness: readiness must reflect whether the selected mode is ready, not whether ordinary application writes are enabled. A healthy backup-mode service may intentionally reject normal application operations.

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
