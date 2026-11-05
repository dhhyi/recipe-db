# Bazel disk-cache workflow artifacts

The Publish `quality-checks` job uses completed Bazel disk-cache snapshots as workflow artifacts. This replaces only the Bazel `actions/cache` step. Mise tool caching, the quality gates, WIP handling, integration/image jobs, and other workflow artifacts are unchanged.

## Contract

The mechanism uses format `recipe-db-bazel-disk-cache` version 1. Each artifact contains `manifest.json` and one `snapshot.tar`. Artifact names are:

- `bazel-cache-v1-main-r<RUN_ID>-a<ATTEMPT>`
- `bazel-cache-v1-pr-<PR_NUMBER>-r<RUN_ID>-a<ATTEMPT>`

The manifest records repository, workflow file, job, run ID and attempt, event, actual built commit, PR number/head/base when applicable, cache-format version, Bazel version, operating system, architecture, digest algorithm, and the snapshot size and SHA-256. Run and PR identity is checked against GitHub's run, attempt, artifact, and job-step metadata; manifest claims alone are not trusted. PR head identity is checked separately, and the built merge commit's parents are verified against the producer-time PR head and base revisions.

Compatibility requires the same cache format, `.bazelversion`, OS, architecture, and SHA-256. The Bazel action environment and declared inputs remain the invalidation mechanism. The helper archives only the completed `ac/` and `cas/` layouts; temporary `tmp/` entries are excluded. Other cache layouts, links, special files, malformed ActionResult records, invalid CAS digests, and missing or wrong-size referenced content reject that snapshot as a whole. Regular outputs, output trees, inline outputs, and safe output symlinks are validated before the snapshot is published or restored.

Restore uses one snapshot at a time and completes before Bazel starts:

- PR builds prefer the newest earlier compatible artifact for that same PR, ordered by run number and attempt, without requiring ancestry after a force push. If none is usable, they try trusted main snapshots.
- Main builds consider only main push artifacts whose revisions occur on the built revision's first-parent history. The closest revision wins, with run number and attempt breaking ties.
- A main revision associated by GitHub commit/PR metadata with exactly one squash-merged PR on `main` attempts a two-source restore. The PR snapshot must be for the PR's final head, not its synthetic CI merge revision or the resulting squash commit. Its paired main snapshot must precede the squash commit on first-parent history. Other main revisions use the incremental-main path.
- An artifact from the current in-progress attempt is excluded. A prior attempt of the same run can be considered.

For a squash restore, both artifacts are staged and validated independently before union and before Bazel starts. Main imports a PR artifact only when the merged PR's head repository is this repository and GitHub run/attempt metadata identifies the producer as a repository writer with `write`, `maintain`, or `admin` permission. Fork-produced artifacts are never imported into main. Missing or ambiguous association, an ineligible producer, or an unavailable final-head artifact falls back to main-only; an eligible PR artifact can seed the build by itself if no preceding main snapshot is available. If neither source is usable, the build starts cold. API errors, ordinary misses, trust rejections, and invalid snapshots have distinct diagnostics.

The union deduplicates identical CAS entries, rejects different bytes under the same CAS digest, combines action-result keys, and keeps main's valid result for conflicting action keys while retaining both sources' CAS blobs. Both sources must pass the normal complete snapshot validation; an invalid source is rejected as a whole and is not repaired from the other. The workflow never imports output bases or active cache directories.

The artifact is uploaded once after both Bazel stages succeed and before integration or image validation. Therefore a later job failure does not make the completed snapshot ineligible. Main artifacts retain for 90 days; PR artifacts retain for seven days.

## Nightly cleanup

The Publish workflow runs cleanup daily at 03:17 UTC from trusted default-branch code. Only `cleanup-bazel-cache` receives `actions: write`; quality and PR jobs retain read-only artifact permissions. The scheduled job does not run the quality, integration, or image-validation jobs.

Cleanup paginates the repository artifact listing and considers only exact `bazel-cache-v1-main-r<RUN_ID>-a<ATTEMPT>` and `bazel-cache-v1-pr-<PR_NUMBER>-r<RUN_ID>-a<ATTEMPT>` names. Before deletion it checks the artifact ID and run ID/attempt against the producing run, repository, workflow path/name, event and branch/PR identity, and successful cache-upload step. Main artifacts are ranked by producer run number and attempt, retaining the newest five; upload completion order is not used. PR artifacts are deleted only after the repository PR API confirms that PR is merged. Open and closed-but-unmerged PR artifacts are left for their seven-day expiry.

An artifact that disappears between listing and deletion is treated as already gone, so rerunning cleanup is safe. Unverifiable artifacts are not deleted. API authorization, service, identity, and deletion errors are reported and make the job fail as incomplete; a partial cleanup is never reported as complete. Cleanup does not coordinate with builds or delete artifacts at merge time, so a concurrent restore can observe a cache miss and fall back.

## Safety limits and fallback

The helper stages downloads privately and does not use archive extraction helpers that write paths directly. It bounds compressed and expanded bytes, file count, per-file size, and action metadata; rejects absolute/traversing paths, duplicate members, links, special files, tar extension records, and unrecognized layouts; and only exposes a snapshot after full cache validation. Compatibility, integrity, and identity failures reject the complete candidate. The existing destination is never overwritten.

The v1 limits are an 8 GiB downloaded workflow ZIP and snapshot tar, 12 GiB expanded cache data, 500,000 cache entries and expanded output-tree nodes, 64 MiB of expanded output-tree metadata and paths per ActionResult, 2 GiB per cache file, 1 MiB for manifest/API metadata and ZIP directory data, and 64 MiB per ActionResult or Tree record. Output-tree nesting is limited to 256 levels. Exceeding any limit rejects the whole candidate or skips upload; it never truncates a snapshot.

Missing, expired, or concurrently deleted artifacts are ordinary misses: the selector tries another eligible candidate and ultimately runs Bazel cold if needed. API authorization, service, and download errors are logged separately from misses. Cache lookup and snapshot-preparation errors do not skip quality checks or convert their result to success; an upload-action failure is non-blocking.

The workflow log reports each selected producer run/attempt and built revision, PR head/base and squash revision, compatibility and writer-trust decisions, action-key conflicts, fallback/rejection reason, cache action hits and executions from Bazel execution logs, snapshot preparation/restore/union times, archive and expanded sizes, and helper peak resident memory. The upload-artifact step's duration and transfer diagnostics are available in the Actions job log.

## Rebuild diagnostics

The shared `mise run --raw bazel build ...` wrapper enables `--subcommands`, `--explain`, and `--verbose_explanations` for CI and pre-commit builds. It prints executed commands during the build and the rebuild explanations afterwards, including on failure, while preserving Bazel's exit status. These flags report the current build; they do not run a separate dry run.

Each invocation retains a unique timestamped explanation log under `${TMPDIR:-/tmp}`, or `BAZEL_DIAGNOSTICS_DIR` when set. CI uses the runner's temporary diagnostics directory and uploads its logs as `bazel-rebuild-explanations` with seven-day retention even if a build fails. Non-build commands and invocations with Bazel startup options before `build` pass through unchanged.

Explanations can identify changed inputs or action commands when the local action cache has prior state. CI restores only the disk cache, not the output base/local action cache, so a fresh runner may report missing prior action state rather than a specific changed file. Combine the explanations with the existing execution-log cache-hit counts and snapshot restore diagnostics; a missing local action record alone does not prove a disk-cache miss.

## Trust and evidence boundary

Trusted repository writers can supply action-result metadata. CAS digest validation and main-wins conflict resolution do not authenticate PR-only action results; this is an explicit trust choice, not proof that those actions were honestly executed. Read-only build permissions remain unchanged, and the workflow does not grant PR code artifact-deletion or repository-write credentials.

The automated fixtures cover selection, trust decisions, union conflicts, retained blobs, output metadata, whole-snapshot rejection, and cleanup ranking/identity/failure behavior. Available hosted runs provide these observations:

| Workflow run | Path and result | Bazel/action observations | Snapshot upload |
| --- | --- | --- | --- |
| [#41725642521](https://github.com/dhhyi/recipe-db/actions/runs/41725642521) | Main push `f0471cd`; quality checks succeeded | 66 total actions; 0 format and 0 check-cache hits; 19 format and 65 check actions executed | 1,679,360-byte snapshot; 197,521-byte artifact; 28,491,776-byte helper peak RSS |
| [#41732074594](https://github.com/dhhyi/recipe-db/actions/runs/41732074594) | PR #152; quality checks succeeded | 66 total actions; 19 format hits; 62 check hits and 3 check executions | 1,679,360-byte snapshot; 198,358-byte artifact; 29,351,936-byte helper peak RSS |
| [#41739534628](https://github.com/dhhyi/recipe-db/actions/runs/41739534628) | Main push `7cfca9c`, the squash merge of PR #152; quality checks succeeded | 66 total actions; 19 format hits; 62 check hits and 3 check executions | 1,679,360-byte snapshot; 198,299-byte artifact; 29,253,632-byte helper peak RSS |
| [#41602977451](https://github.com/dhhyi/recipe-db/actions/runs/41602977451) | Earlier main run `2a414be`, before artifact transport | 66 total actions; 62 disk-cache hits, 3 local actions | Old Cache Action baseline; inputs/revision and exact tool/cache environment are not comparable to the later runs |

These are observations, not evidence of production speedup. The accessible run logs do not establish selected producer identities for the two cache-hit builds, attribute hits separately to the main and PR sides of the squash union, or provide comparable old/new inputs. Restore-step durations combine API lookup, transfer, validation, and union (37 seconds for PR #152 and 29 seconds for the squash-merge main run); upload steps took about two seconds. Snapshot preparation totaled 0.054 seconds for the main run, 0.062 seconds for the PR run, and 0.077 seconds for the squash-merge main run. These are not end-to-end transfer/merge measurements, and helper RSS is not peak job memory.

The logs also do not demonstrate production hits unique to each source snapshot, changed-input invalidation with clean-build output/executable equality across the deployed path, or a controlled old-Cache-Action comparison. The accepted bounded PoC remains proof-of-concept evidence only. Do not infer success from the hit counts above or from artifact selection; representative source-attributed CI runs and a comparable baseline remain required for the parent's full validation contract.
