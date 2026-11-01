# Agent instructions

## README changes

Do not add new content to README.md files unless the user explicitly asks for it. Update existing content when changes make it outdated.

## GraphQL access boundary

All normal client data operations go through GraphQL via trusted ingress. Do not introduce direct client-to-backend access. Backend maintenance APIs must remain private and be available only in backup mode. Testing-only data-reset APIs are a separate private interface, available only in testing mode, not backup mode. Public static/image delivery is an intentional exception.

Every API/backend project must declare a `backupRole` in its `.project.yaml`. Services classified as an authoritative source or cleanup participant must implement the versioned private maintenance API described in [the production Kubernetes operations guide](docs/production-kubernetes.md). Do not expose maintenance or test-reset routes through ingress, GraphQL, or MCP.

## GitHub issue planning

Follow [CONTRIBUTING.md](CONTRIBUTING.md) for the canonical issue refinement process. Use GitHub issues to plan and refine future work, not to track ad-hoc work performed in the current session.

- Create issues when the user asks to capture, plan, refine, or defer work for later implementation.
- Do not create an issue merely because the user requests an immediate fix, investigation, or code change. Handle that work directly in the session.
- When working on an existing issue, keep it and any relevant umbrella issue current. Do not create another issue for the same work.
- If you discover follow-up work outside the current scope, mention it; do not create an issue unless the user asks.

- Give each issue exactly one workflow label: `idea`, `umbrella`, `spec`, or `decision`; other metadata labels may coexist. Replace the workflow label only when the issue type changes during refinement, preserving the issue and discussion.
- Capture problems and feature wishes as `idea`, with context and optional implementation hints, not a full specification. Research, exploration, and unresolved requirements remain `idea`.
- Refine standalone ideas into `spec` or `umbrella`, never `decision`. A `spec` must settle material requirements and define scope, behavior, constraints, dependencies, and verifiable acceptance criteria for autonomous implementation; minor implementation choices remain open to agent judgment and review.
- Refinement also supports revising specs and restructuring umbrellas. When splitting a spec, convert the existing issue into an umbrella, preserve settled requirements, acceptance criteria, and progress across its children and completion criteria, and review affected dependencies. Fully settled split-out children may be specs directly; unresolved new scope remains ideas.
- Create `decision` records only under an umbrella. Record context, chosen approach, alternatives, and consequences; link accepted decisions as the umbrella's base contract and require child specs to conform. Close accepted decisions; explicitly supersede material contract changes and review affected specs.
- Model dependencies with GitHub's native "blocked by" feature, including cross-umbrella and standalone dependencies, not labels or diagrams alone. Implement specs only after blockers are resolved; clarify material ambiguities before proceeding.
- Close specs after verifying acceptance criteria, not merely after refinement.

### Keeping umbrella issues current

Umbrella issues track larger outcomes through native sub-issues. New unresolved scopes start as `idea` and may become specs, decisions, or umbrellas; preserve existing specs and create fully settled split-out scopes directly as specs. Define scope and completion criteria. Whenever a child, dependency, or decision changes, update the umbrella's main description and diagram in the same task to reflect its base contract, progress, open questions, and next steps rather than relying only on comments. Keep refinement distinct from implementation and close the umbrella only when its overall completion criteria are met.

Only issues labeled `umbrella` may have sub-issues. Attach sub-issues directly to the appropriate umbrella; do not nest them under ordinary issues. If a non-umbrella issue already has sub-issues, move those children to its umbrella.

Every umbrella issue must include a Mermaid `flowchart TD` showing implementation order and dependencies among its direct sub-issues. Each node label must contain only the issue number and current issue title, followed by ` (closed)` if the issue is closed (for example, `#123 Issue title (closed)`). Do not add other metadata to node labels or include PR references anywhere in the diagram. Every node representing an issue must link to its GitHub URL using a Mermaid `click` directive. Use prerequisite-to-dependent arrows matching native GitHub "blocked by" dependencies. Document external dependencies separately, outside this diagram; contract references are not automatically blockers. Prefer a flowchart over a Gantt chart because these plans express dependencies, not dates.

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

When running checks, linting, or regression tests for Bazel scripts, run them directly on the host from the repository root, not inside any project's devcontainer. This is an exception to the project-tooling and precommit-check rules, not a requirement to duplicate the pre-commit hook's checks.

For a single topic group, use `mise run test-scripts <group>` or `mise run --raw bazel build --action_env=PATH --jobs=1 //:test_scripts_<group>`. Use the `bazel` Mise task for direct Bazel commands, as the hook and CI do: it constructs PATH from Mise-managed tool directories, the Mise executable's directory and fixed system directories (`/usr/local/bin:/usr/bin:/bin`), excluding caller-specific Git/VS Code paths. Keep `--action_env=PATH` on builds so tool-path changes still invalidate actions. Groups and their explicit inputs are defined in `.scripts/tests/groups.yaml`: `compose`, `release`, `deploy`, `tasks`, `devcontainer`, and `tooling`. Assign every new Bats suite to exactly one group and keep its inputs complete; generation rejects unassigned suites and patterns matching no files.

Project generator, format, and check commands invoked by Bazel must still run in their respective devcontainers.

## Committing during autonomous implementation

Unless the user asks to leave changes uncommitted, commit each self-contained implementation step before moving to the next instead of waiting until the whole task is done. Sessions can time out and lose uncommitted work.

The pre-commit hook runs ShellCheck, all script regression test groups, and applicable project formatting/checks. Do not manually duplicate these standard checks before committing. During development, run only targeted tests needed to reproduce a bug or verify an intermediate change, preferably through the corresponding Bazel target so pre-commit can reuse its cache. Run broader checks manually only when explicitly requested, diagnosing a hook failure, or when no commit will be made.

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

Every service container (including shell wrappers and sidecars) must exit 0 within seconds of SIGTERM. Containers run the service as PID 1, where the kernel ignores signals without an installed handler, so install one explicitly (or `trap` TERM in shell commands). Backup capture refuses Pods that were SIGKILLed (exit 137); the 120-second termination grace is only an upper bound, not a substitute for clean exit.

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
