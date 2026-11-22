# Bazel disk-cache workflow artifacts

This guide describes the Bazel disk-cache artifact lifecycle for maintainers of the Publish workflow and CI. It covers artifact selection, validation, cleanup, and cache-miss behavior; the [production release guide](production-releases.md) describes the separate immutable application release artifacts.

**Table of contents**

- [Contract](#contract)
- [Timestamp-aware pruning and cache health](#timestamp-aware-pruning-and-cache-health)
- [Nightly cleanup](#nightly-cleanup)
- [Safety limits and fallback](#safety-limits-and-fallback)
- [Rebuild diagnostics](#rebuild-diagnostics)
- [Trust and evidence boundary](#trust-and-evidence-boundary)

The Publish `quality-checks` job uses completed Bazel disk-cache snapshots as workflow artifacts. This replaces only the Bazel `actions/cache` step. Mise tool caching, the quality gates, WIP handling, integration/image jobs, and other workflow artifacts are unchanged. The `//:all` validation runs before snapshot preparation and upload, so successful message-bus and migrator-packaging actions can be reused by later builds without starting their test containers.

## Contract

The mechanism uses format `recipe-db-bazel-disk-cache` version 2 for direct-source builds. Each artifact contains `manifest.json` and one `snapshot.tar`. Artifact names are:

- `bazel-cache-v2-<JOB>-main-r<RUN_ID>-a<ATTEMPT>`
- `bazel-cache-v2-<JOB>-pr-<PR_NUMBER>-r<RUN_ID>-a<ATTEMPT>`

`<JOB>` is passed explicitly as `GITHUB_JOB`. Jobs do not share restore candidates or main-artifact retention. The unnamed v1 names and earlier unnamed v2 names remain recognizable only for cleanup and legacy migration handling; cleanup treats them as `quality-checks` artifacts.

Every build job checks out its event's exact commit and verifies `git rev-parse HEAD` against that SHA before building. Pull-request runs use `pull_request.head.sha`, not the moving branch or virtual merge ref; main push runs use the push SHA. The manifest records repository, workflow file, job, run ID and attempt, event, source/built commit, producer run head SHA, and PR number/head/base context when applicable, plus cache compatibility and snapshot digest data. For PR artifacts, the source, built commit, producer run head, and recorded PR head must be identical. The base SHA is diagnostic context only.

Run and PR identity is checked against GitHub's run, attempt, artifact, and successful upload-step metadata; manifest and artifact-name claims alone are not trusted. The producer's immutable recorded head is resolved through GitHub's commit-to-PR API. That lookup must identify exactly one eligible PR in the repository and match the requested PR. Embedded run/check-suite PR arrays and current PR head/base values are not required to authenticate historical builds.

Compatibility requires the same cache format, `.bazelversion`, OS, architecture, and SHA-256. The Bazel action environment and declared inputs remain the invalidation mechanism. The helper archives only the completed `ac/` and `cas/` layouts; temporary `tmp/` entries are excluded. Other cache layouts, links, special files, malformed ActionResult records, invalid CAS digests, and missing or wrong-size referenced content reject that snapshot as a whole. Regular outputs, output trees, inline outputs, and safe output symlinks are validated before the snapshot is published or restored.

Restore uses one snapshot at a time and completes before Bazel starts:

- PR builds prefer the newest earlier compatible artifact for that same PR, ordered by run number and attempt, without requiring ancestry after a force push. Discovery queries only Publish pull-request runs on the PR head branch and inspects at most 100 runs and attempts at most 20 candidates. If none is usable, they independently try trusted main snapshots.
- Main builds consider only the latest 20 Publish push runs on `main` whose revisions occur on the built revision's first-parent history. The closest revision wins, with run number and attempt breaking ties. If none is usable, the build starts cold.
- A main revision associated by GitHub commit/PR metadata with exactly one squash-merged PR on `main` attempts a two-source restore. The PR snapshot must be for the PR's final head, not its synthetic CI merge revision or the resulting squash commit. Its paired main snapshot must precede the squash commit on first-parent history. Other main revisions use the incremental-main path.
- An artifact from the current in-progress attempt is excluded. A prior attempt of the same run can be considered.

For a squash restore, both artifacts are staged and validated independently before union and before Bazel starts. Main imports a PR artifact only when the merged PR's head repository is this repository and the producer passes the authenticated identity policy below. Fork-produced artifacts are never imported into main. Missing or ambiguous commit-to-PR association, an ineligible producer, or an unavailable final-head artifact falls back to main-only; an eligible PR artifact can seed the build by itself if no preceding main snapshot is available. If neither source is usable, the build starts cold. API errors, ordinary misses, trust rejections, and invalid snapshots have distinct diagnostics.

The union deduplicates identical entries, rejects different bytes under the same CAS digest, combines action-result keys, and keeps main's valid result for conflicting action keys while retaining both sources' CAS blobs. Identical action results and CAS entries retain the newer last-use timestamp. Both sources must pass the normal complete snapshot validation; an invalid source is rejected as a whole and is not repaired from the other. The workflow never imports output bases or active cache directories.

After source verification succeeds, snapshot preparation runs even if formatting or Bazel checks fail or the job is cancelled, when cache inspection succeeds. Upload runs once before integration or image validation when preparation succeeds and produces a validated snapshot. Completed actions remain reusable even when another action fails; incomplete temporary entries are excluded. A failed or cancelled producer remains eligible only if its cache-upload step succeeded. Cache preservation does not change the original quality-check result, and runner termination can still prevent an upload. Main artifacts retain for 90 days; PR artifacts retain for seven days.

## Timestamp-aware pruning and cache health

Cache-file modification times represent Bazel last use: Bazel refreshes an ActionResult and its referenced blobs on a disk-cache hit, and newly stored entries also receive a recent mtime. The helper archives these whole-second mtimes in the tar headers and restores them on extraction. It does not use atime, refresh old entries during restore, or assign a new baseline to zero timestamps. Negative timestamps and timestamps more than five minutes in the future reject the candidate and follow normal restore fallback; up to five minutes of clock skew is accepted.

Identical entries from a main/PR union use the newer timestamp. A conflicting ActionResult keeps main's bytes and timestamp; the discarded PR result cannot make the main result appear recently used. Unique PR entries retain their own last-use time.

Only a main push whose formatting and Bazel checks both succeeded is eligible for pruning. PRs and failed, skipped, or interrupted main checks preserve the cache without age expiry or size trimming, then validate and upload it when possible. Thus failed-main snapshots can temporarily exceed the policy. A later successful main run applies the policy and protects every ActionResult used or generated since the quality-check build began, along with its complete referenced content.

The policy counts uncompressed cache-file payload, counting shared blobs once; tar headers and compressed artifact size are diagnostic only. On eligible runs:

1. A protected working set above 4 MiB fails cache preparation with a parameter-tuning diagnostic; required content is never evicted.
2. Historical ActionResults last used more than 14 days ago expire. Content not referenced by any retained result, including orphan CAS blobs, is removed.
3. If the remaining cache-file payload exceeds 10 MiB, the helper starts with the protected set and adds historical results newest first, breaking ties by action key. The trigger counts orphan CAS bytes too, but orphans are never history candidates and are removed when pruning runs. It stops at the first result that reaches or crosses 4 MiB, keeping that whole result. It does not backfill with smaller entries. The target is soft, so one large result may overshoot it.
4. Below the 10 MiB trigger, non-expired history remains intact unless it is expired by age.

Existing zero-timestamp snapshots are reusable. On the first eligible successful main run, unused zero-timestamp results are older than the 14-day cutoff and expire; the current-build working set is refreshed by Bazel and protected. This is the intended lukewarm reset, not a format migration or grace period.

The quality-checks job reports cache restore, inspection, pruning, preparation, validation, and upload outcomes separately, using each step's actual outcome even when `continue-on-error` is set. Inspection reports total and protected payload, expiry findings, and whether pruning is needed. Pruning reports its reasons, before/after payload and entry counts, protected-set size, removals, target overshoot, and duration. Any failed preparation prevents upload. Cache-only failures do not mask or replace the quality-check result.

The main-only `cache-health` job reads those outputs and performs no cache transfer, pruning, or build. It is skipped when no pruning was needed and cache saving succeeded (or was genuinely not attempted). It succeeds only when required pruning and the validated snapshot upload both succeed; preparation, pruning, validation, upload, or reported restore failures make it red. A missing outcome after otherwise successful quality checks is also an error. Repeated green runs indicate frequent pruning and may mean the age/size parameters need tuning. Neither publication job depends on cache health, so cache failures mark the workflow overview red without blocking publication when quality checks and ARM64 validation succeeded.

## Nightly cleanup

The Bazel cache cleanup workflow runs daily at 03:17 UTC or manually through `workflow_dispatch`, only on `main` using trusted default-branch code. Run it manually with `gh workflow run bazel-cache-cleanup.yaml --ref main`. Only `cleanup-bazel-cache` receives `actions: write`; quality and PR jobs retain read-only artifact permissions. Cleanup does not run the quality, integration, or image-validation jobs. Dispatches on other branches skip the cleanup job.

Cleanup paginates the repository artifact listing and considers exact job-aware v2 names, existing unnamed v2 names, and exact v1 legacy names. Before deletion it checks the artifact ID and run ID/attempt against the producing run, repository, workflow path/name, event, branch/PR identity, named producer job, and successful cache-upload step. Existing unnamed artifacts are treated as `quality-checks` artifacts. The artifact's `workflow_run` supplies run/repository/head-repository IDs, head SHA and branch, but no event; cleanup authenticates those fields against the producer-attempt API and derives event/scope from that authenticated run. PR identity is resolved from the run's immutable head SHA through commit-to-PR lookup. GitHub may no longer associate a force-pushed historical head with its PR; because restore also rejects such artifacts, cleanup deletes them after verifying the producer run and successful upload step. Ambiguous or mismatched associations and API errors remain fatal, and unverifiable artifacts are never deleted. Main artifacts are grouped by job and ranked by producer run number and attempt, retaining the newest five for each job independently; upload completion order is not used. A verification failure affects only the main-retention group for that job. Other PR artifacts are deleted only after the repository PR API confirms that PR is merged. Open and closed-but-unmerged PR artifacts are left for their seven-day expiry. Legacy v1 PR artifacts are never restored; cleanup may delete them only after the same independent run/head/PR authentication, otherwise they remain until expiry with an identity diagnostic.

An artifact that disappears between listing and deletion is treated as already gone, so rerunning cleanup is safe. Unverifiable artifacts are not deleted. API authorization, service, other identity, and deletion errors are reported and make the job fail as incomplete; a missing historical commit association is logged as a deletion reason. A partial cleanup is never reported as complete. Cleanup does not coordinate with builds or delete artifacts at merge time, so a concurrent restore can observe a cache miss and fall back.

## Safety limits and fallback

The helper stages downloads privately and does not use archive extraction helpers that write paths directly. It bounds compressed and expanded bytes, file count, per-file size, and action metadata; rejects absolute/traversing paths, duplicate members, links, special files, tar extension records, and unrecognized layouts; and only exposes a snapshot after full cache validation. Compatibility, integrity, and identity failures reject the complete candidate. The existing destination is never overwritten.

The limits are an 8 GiB downloaded workflow ZIP and snapshot tar, 12 GiB expanded cache data, 500,000 cache entries and expanded output-tree nodes, 64 MiB of expanded output-tree metadata and paths per ActionResult, 2 GiB per cache file, 1 MiB for manifest/API metadata and ZIP directory data, and 64 MiB per ActionResult or Tree record. Output-tree nesting is limited to 256 levels. Exceeding any limit rejects the whole candidate or skips upload; it never truncates a snapshot.

Missing, expired, or concurrently deleted artifacts are ordinary misses: the selector tries another eligible candidate and ultimately runs Bazel cold if needed. Legacy v1 PR snapshots are explicitly skipped during migration; v1 main snapshots also produce a migration diagnostic and are not interpreted as v2. API authorization, service, and download errors are logged separately from misses. Safe read requests use bounded retries for transient connection failures; deletion outcomes are confirmed or reported incomplete. Cache lookup and snapshot-preparation errors do not skip quality checks or convert their result to success; an upload-action failure is non-blocking.

The workflow log reports inspected-run and attempted-candidate counts and the stop reason for each discovery, each selected producer run/attempt and built revision, PR head/base and squash revision, compatibility and writer-trust decisions, action-key conflicts, fallback/rejection reason, cache action hits and executions from Bazel execution logs, snapshot preparation/restore/union times, archive and expanded sizes, and helper peak resident memory. The upload-artifact step's duration and transfer diagnostics are available in the Actions job log.

## Rebuild diagnostics

The shared `mise run --raw bazel build ...` wrapper enables `--explain` and `--verbose_explanations` only when `BAZEL_DIAGNOSTICS_DIR` is non-empty, as configured by CI. Pre-commit builds leave it unset and use normal Bazel output without extra diagnostics. When enabled, the wrapper saves rebuild explanations to a file, including on failure, while preserving Bazel's exit status. These flags report the current build; they do not run a separate dry run.

Each diagnostics-enabled invocation retains a unique timestamped explanation log under `BAZEL_DIAGNOSTICS_DIR`. CI uses the runner's temporary diagnostics directory and uploads its logs as `bazel-rebuild-explanations` with seven-day retention even if a build fails. Non-build commands and invocations with Bazel startup options before `build` pass through unchanged.

CI also uploads the available formatting and check execution logs as `bazel-execution-logs` with seven-day retention, including after a build failure. These JSON logs contain action commands, environment variables, and cache information; they are not identical to Bazel's subcommand output.

Generated project actions merge stderr into stdout before Bazel captures their output, keeping GitHub Actions group markers in order with the command output they enclose.

Explanations can identify changed inputs or action commands when the local action cache has prior state. CI restores only the disk cache, not the output base/local action cache, so a fresh runner may report missing prior action state rather than a specific changed file. Combine the explanations with the existing execution-log cache-hit counts and snapshot restore diagnostics; a missing local action record alone does not prove a disk-cache miss.

## Cacheable integration validations

The generated Bazel targets `//:message_bus_validation` and `//:migrator_packaging_validation` wrap the existing Mise validation commands. `//:all` runs both in the Publish quality-checks job, before cache snapshot preparation. Execution-log reporting distinguishes an executed action from a successful disk-cache hit; on a hit, Bazel reuses the result without starting the validation's test containers. The existing Mise commands remain available for direct use.

The message-bus target declares the GraphQL compilation sources, tests, manifests and lockfile, project/devcontainer configuration and task mapping, runner helpers, NATS configuration, and the pinned NATS image reference as inputs. The migrator-packaging target declares its release-metadata scripts, manifest schema, fixtures, and shared migration-Job template/helper inputs. Generated source discovery includes additions and removals, so those alter the relevant target's inputs; the targets do not use the Git revision or unrelated repository files as cache keys. Their dependency sets are independent.

The workflow execution log distinguishes a cache hit from an executed action. A hit reuses the successful validation result without starting its test containers; a miss runs the validation, and either test or cleanup failures remain build failures.

The ARM64 validation job generates one `//:integration_suite_<project>` target per integration suite. Its inputs include the suite's selected-platform runnable image manifest digest, the reachable project image digests, reachable project metadata, and the shared runner, Compose-generation, tool, and Bazel inputs. NATS configuration is included only for suites whose dependency graph reaches the synthetic `nats` node. Dependency categories expand transitively; cycles are allowed and each project is collected once. A suite with no resolved project or synthetic dependency always runs directly through the uncached single-suite runner; the CI orchestrator does not rely on Bazel's `no-cache` tag, which does not prevent local action-cache reuse.

The ARM64 workflow builds Compose images once, records their Buildx manifest metadata, resolves identities for the Docker daemon's selected platform, then starts the development stack and runs suite targets sequentially. For a local image index, identity collection selects the available runnable manifest, not an attestation, and fails if the index or platform selection is missing or ambiguous. The cached runner uses `docker compose run --pull never`, so a cache miss runs against the already-prepared images without rebuilding or replacing them. Each suite writes its normal report log; a failure stops later suites and does not produce a cacheable success output. The existing local `mise run integration-tests -- --development` path remains uncached.

ARM64 snapshots use the existing job-aware artifact mechanism under the `arm64-validation` job name, separate from `quality-checks`. Missing or unusable snapshots are ordinary cache misses: Bazel executes the suite using the prepared images. Authentication tokens, generated Compose output, mutable tags, attestations, and unrelated projects' routing metadata are not suite cache inputs.

## Trust and evidence boundary

Human producers must have the same valid `(id, login, type)` tuple in both workflow-run and producer-attempt metadata, with `type: User`; their login must independently pass the repository collaborator permission check with `write`, `maintain`, or `admin`. The one explicitly authorized bot is the immutable tuple `id: 198982749`, `login: Copilot`, `type: Bot`. That tuple must match in both metadata records, and both records must also pass the existing same-repository and recorded head-repository checks. Only then is it accepted as the pinned Copilot authorization, without a collaborator lookup. Missing, malformed, mismatched, or drifted identity metadata fails closed; other bots are not supported. The triggering actor is not a substitute for the recorded producer actor.

This narrowly pins Copilot as an authorized producer because its PR build may write action-result metadata later consumed by main. Cache digest/output validation, provenance checks, and main-wins conflict resolution remain required, but they do not prove PR-only action results were honestly executed; accepting this exact bot is an explicit trust choice. Read-only build permissions remain unchanged, and the workflow does not grant PR code artifact-deletion or repository-write credentials. Logs distinguish pinned Copilot authorization, human collaborator trust, unsupported or mismatched bot identity, missing/malformed identity, API authorization failures, and invalid cache contents.

The automated fixtures cover selection, trust decisions, union conflicts, retained blobs, output metadata, whole-snapshot rejection, and cleanup ranking/identity/failure behavior. Available hosted runs provide these observations:

| Workflow run | Path and result | Bazel/action observations | Snapshot upload |
| --- | --- | --- | --- |
| [#41725642521](https://github.com/dhhyi/recipe-db/actions/runs/41725642521) | Main push `f0471cd`; quality checks succeeded | 66 total actions; 0 format and 0 check-cache hits; 19 format and 65 check actions executed | 1,679,360-byte snapshot; 197,521-byte artifact; 28,491,776-byte helper peak RSS |
| [#41732074594](https://github.com/dhhyi/recipe-db/actions/runs/41732074594) | PR #152; quality checks succeeded | 66 total actions; 19 format hits; 62 check hits and 3 check executions | 1,679,360-byte snapshot; 198,358-byte artifact; 29,351,936-byte helper peak RSS |
| [#41739534628](https://github.com/dhhyi/recipe-db/actions/runs/41739534628) | Main push `7cfca9c`, the squash merge of PR #152; quality checks succeeded | 66 total actions; 19 format hits; 62 check hits and 3 check executions | 1,679,360-byte snapshot; 198,299-byte artifact; 29,253,632-byte helper peak RSS |
| [#41602977451](https://github.com/dhhyi/recipe-db/actions/runs/41602977451) | Earlier main run `2a414be`, before artifact transport | 66 total actions; 62 disk-cache hits, 3 local actions | Old Cache Action baseline; inputs/revision and exact tool/cache environment are not comparable to the later runs |

These are observations, not evidence of production speedup. The accessible run logs do not establish selected producer identities for the two cache-hit builds, attribute hits separately to the main and PR sides of the squash union, or provide comparable old/new inputs. Restore-step durations combine API lookup, transfer, validation, and union (37 seconds for PR #152 and 29 seconds for the squash-merge main run); upload steps took about two seconds. Snapshot preparation totaled 0.054 seconds for the main run, 0.062 seconds for the PR run, and 0.077 seconds for the squash-merge main run. These are not end-to-end transfer/merge measurements, and helper RSS is not peak job memory.

The logs also do not demonstrate production hits unique to each source snapshot, changed-input invalidation with clean-build output/executable equality across the deployed path, or a controlled old-Cache-Action comparison. The accepted bounded PoC remains proof-of-concept evidence only. Do not infer success from the hit counts above or from artifact selection; representative source-attributed CI runs and a comparable baseline remain required for the parent's full validation contract.
