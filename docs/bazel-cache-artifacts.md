# Bazel disk-cache workflow artifacts

The Publish `quality-checks` job uses completed Bazel disk-cache snapshots as workflow artifacts. This replaces only the Bazel `actions/cache` step. Mise tool caching, the quality gates, WIP handling, integration/image jobs, and other workflow artifacts are unchanged.

## Contract

The mechanism uses format `recipe-db-bazel-disk-cache` version 1. Each artifact contains `manifest.json` and one `snapshot.tar`. Artifact names are:

- `bazel-cache-v1-main-r<RUN_ID>-a<ATTEMPT>`
- `bazel-cache-v1-pr-<PR_NUMBER>-r<RUN_ID>-a<ATTEMPT>`

The manifest records repository, workflow file, job, run ID and attempt, event, actual built commit, PR number/head/base when applicable, cache-format version, Bazel version, operating system, architecture, digest algorithm, and the snapshot size and SHA-256. Run and PR identity is checked against GitHub's run, attempt, artifact, and job-step metadata; manifest claims alone are not trusted. PR merge commits are recorded as the built commit, separately from PR head and base revisions.

Compatibility requires the same cache format, `.bazelversion`, OS, architecture, and SHA-256. The Bazel action environment and declared inputs remain the invalidation mechanism. The helper archives only the completed `ac/` and `cas/` layouts; temporary `tmp/` entries are excluded. Other cache layouts, links, special files, malformed ActionResult records, invalid CAS digests, and missing or wrong-size referenced content reject that snapshot as a whole. Regular outputs, output trees, inline outputs, and safe output symlinks are validated before the snapshot is published or restored.

Restore uses one snapshot at a time and completes before Bazel starts:

- PR builds prefer the newest earlier compatible artifact for that same PR, ordered by run number and attempt, without requiring ancestry after a force push. If none is usable, they try trusted main snapshots.
- Main builds consider only main push artifacts whose revisions occur on the built revision's first-parent history. The closest revision wins, with run number and attempt breaking ties. Artifacts from PR runs are never imported into main by this implementation.
- An artifact from the current in-progress attempt is excluded. A prior attempt of the same run can be considered.

The artifact is uploaded once after both Bazel stages succeed and before integration or image validation. Therefore a later job failure does not make the completed snapshot ineligible. Main artifacts retain for 90 days; PR artifacts retain for seven days. No nightly deletion is implemented here.

## Safety limits and fallback

The helper stages downloads privately and does not use archive extraction helpers that write paths directly. It bounds compressed and expanded bytes, file count, per-file size, and action metadata; rejects absolute/traversing paths, duplicate members, links, special files, and unrecognized layouts; and only exposes a snapshot after full cache validation. Compatibility, integrity, and identity failures reject the complete candidate. The existing destination is never overwritten.

The v1 limits are an 8 GiB downloaded workflow ZIP and snapshot tar, 12 GiB expanded cache data, 500,000 cache entries, 2 GiB per cache file, 1 MiB for manifest/API metadata and ZIP directory data, and 64 MiB per ActionResult or Tree record. Output-tree nesting is limited to 256 levels. Exceeding any limit rejects the whole candidate or skips upload; it never truncates a snapshot.

Missing, expired, or concurrently deleted artifacts are ordinary misses: the selector tries another eligible candidate and ultimately runs Bazel cold if needed. API authorization, service, and download errors are logged separately from misses. Cache lookup and snapshot-preparation errors do not skip quality checks or convert their result to success; an upload-action failure is non-blocking.

The workflow log reports the selected producer and revision, fallback/rejection reason, cache action hits and executions from Bazel execution logs, snapshot preparation and restore times, archive size, and helper peak resident memory. The upload-artifact step's duration and transfer diagnostics are available in the Actions job log.

## Current boundary

This is the single-snapshot foundation only. It does not merge PR and main caches for squash merges, run nightly cleanup, or establish the full three-path CI performance comparison. Those remain the responsibility of the dependent union and cleanup/validation work. CI-scale cache size, action-hit behavior, and resource use should be recorded from representative hosted runs rather than inferred from the bounded fixture tests.
