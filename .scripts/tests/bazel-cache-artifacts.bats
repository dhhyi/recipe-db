#!/usr/bin/env bats

load test_helper

@test "Bazel cache artifact selection and intake tests pass" {
  run env PYTHONDONTWRITEBYTECODE=1 python3 "$BATS_TEST_DIRNAME/bazel-cache-artifacts.py"

  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "Publish restores, validates and uploads Bazel snapshots after cacheable validations" {
  workflow="$BATS_TEST_DIRNAME/../../.github/workflows/publish.yaml"
  restore=$(grep -n '^      - name: restore and union Bazel disk cache artifacts$' "$workflow" | cut -d: -f1)
  format=$(grep -n '^      - name: check project formatting$' "$workflow" | cut -d: -f1)
  checks=$(grep -n '^      - name: Bazel precommit checks, unit tests, and cacheable validations$' "$workflow" | cut -d: -f1)
  inspect=$(grep -n '^      - name: inspect Bazel cache$' "$workflow" | cut -d: -f1)
  prune=$(grep -n '^      - name: prune Bazel cache$' "$workflow" | cut -d: -f1)
  prepare=$(grep -n '^      - name: prepare Bazel cache snapshot$' "$workflow" | cut -d: -f1)
  upload=$(grep -n '^      - name: upload Bazel cache snapshot$' "$workflow" | cut -d: -f1)

  [ "$restore" -lt "$format" ]
  [ "$format" -lt "$checks" ]
  [ "$checks" -lt "$inspect" ]
  [ "$inspect" -lt "$prune" ]
  [ "$prune" -lt "$prepare" ]
  [ "$prepare" -lt "$upload" ]
  run yq -r '.jobs.quality-checks.steps[] | select(.name == "Bazel precommit checks, unit tests, and cacheable validations") | .run' "$workflow"
  [ "$status" -eq 0 ]
  [[ "$output" == *" //:all"* ]]
  run grep -E 'run: mise run test-(message-bus|migrator-packaging)$' "$workflow"
  [ "$status" -eq 1 ]
  grep -F 'actions: read' "$workflow"
  grep -F 'fetch-depth: 0' "$workflow"
  grep -F -- "--run-number \"\$GITHUB_RUN_NUMBER\"" "$workflow"
  # shellcheck disable=SC2016
  run yq -r '.jobs.quality-checks.steps[] | select(.id == "restore-cache") | .run | contains("--job \"$GITHUB_JOB\"")' "$workflow"
  [ "$status" -eq 0 ]
  [ "$output" = true ]
  # shellcheck disable=SC2016
  run yq -r '.jobs.quality-checks.steps[] | select(.id == "prepare-bazel-cache") | .run | contains("--job \"$GITHUB_JOB\"")' "$workflow"
  [ "$status" -eq 0 ]
  [ "$output" = true ]
  grep -F "retention-days: \${{ github.event_name == 'push' && github.ref == 'refs/heads/main' && 90 || 7 }}" "$workflow"
  run grep -F 'uses: actions/cache@' "$workflow"
  [ "$status" -eq 1 ]
  grep -F 'continue-on-error: true' "$workflow"
  grep -F 'def squash_pull_request(' "$BATS_TEST_DIRNAME/../bazel-cache-artifacts.py"
  grep -F 'def trusted_pr_writer(' "$BATS_TEST_DIRNAME/../bazel-cache-artifacts.py"
  grep -F 'def resolve_pr_association(' "$BATS_TEST_DIRNAME/../bazel-cache-artifacts.py"
  grep -F 'def union_caches(' "$BATS_TEST_DIRNAME/../bazel-cache-artifacts.py"
}

@test "each build job checks out and verifies the event source commit" {
  workflow="$BATS_TEST_DIRNAME/../../.github/workflows/publish.yaml"
  # shellcheck disable=SC2016
  expected='${{ github.event.pull_request.head.sha || github.sha }}'

  for job in quality-checks arm64-validation; do
    run env JOB="$job" yq -r '.jobs[strenv(JOB)].steps[] | select(.name == "checkout") | .with.ref' "$workflow"
    [ "$status" -eq 0 ]
    [ "$output" = "$expected" ]
    run env JOB="$job" yq -r '.jobs[strenv(JOB)].steps[] | select(.name == "verify exact source revision") | .env.EXPECTED_SOURCE_SHA' "$workflow"
    [ "$status" -eq 0 ]
    [ "$output" = "$expected" ]
    run env JOB="$job" yq -r '[.jobs[strenv(JOB)].steps[] | select(.name == "verify exact source revision") | .run | contains("git rev-parse HEAD")] | any' "$workflow"
    [ "$status" -eq 0 ]
    [ "$output" = true ]
  done

  for job in publish-devcontainers publish-release; do
    run env JOB="$job" yq -r '.jobs[strenv(JOB)].steps[] | select(.name == "checkout") | .with.ref' "$workflow"
    [ "$status" -eq 0 ]
    # shellcheck disable=SC2016
    [ "$output" = '${{ github.sha }}' ]
    run env JOB="$job" yq -r '.jobs[strenv(JOB)].steps[] | select(.name == "verify exact source revision") | .env.EXPECTED_SOURCE_SHA' "$workflow"
    [ "$status" -eq 0 ]
    # shellcheck disable=SC2016
    [ "$output" = '${{ github.sha }}' ]
  done
  # shellcheck disable=SC2016
  run grep -F -- '--commit "${{ steps.source.outputs.sha }}"' "$workflow"
  [ "$status" -eq 0 ]
  # shellcheck disable=SC2016
  run grep -F '"$GITHUB_SHA"' "$workflow"
  [ "$status" -eq 1 ]
}

@test "Bazel snapshot preservation runs after failures and cancellation with verified source" {
  workflow="$BATS_TEST_DIRNAME/../../.github/workflows/publish.yaml"
  slice="$BATS_TEST_TMPDIR/workflow-slice"
  sed -n '/- name: check project formatting/,/- name: build and validate production AMD64 images for pull requests/p' "$workflow" > "$slice"

  grep -F -- "--execution_log_json_file=\"\$RUNNER_TEMP/bazel-format-execution.json\"" "$slice"
  grep -F -- "--execution_log_json_file=\"\$RUNNER_TEMP/bazel-check-execution.json\"" "$slice"
  grep -F 'steps.prepare-bazel-cache.outputs.name' "$slice"
  run yq -r '.jobs.quality-checks.steps[] | select(.id == "prepare-bazel-cache") | .if' "$workflow"
  [ "$status" -eq 0 ]
  [[ "$output" == *"always()"* ]]
  [[ "$output" == *"steps.source.outcome == 'success'"* ]]
  [[ "$output" == *"steps.inspect-cache.outcome == 'success'"* ]]

  run yq -r '.jobs.quality-checks.steps[] | select(.name == "upload Bazel cache snapshot") | .if' "$workflow"
  [ "$status" -eq 0 ]
  [ "$output" = "always() && steps.prepare-bazel-cache.outcome == 'success' && steps.prepare-bazel-cache.outputs.name != ''" ]

  for step in restore-cache inspect-cache prune-cache prepare-bazel-cache upload-cache; do
    run env STEP="$step" yq -r '.jobs.quality-checks.steps[] | select(.id == strenv(STEP)) | .continue-on-error' "$workflow"
    [ "$status" -eq 0 ]
    [ "$output" = true ]
  done
  run yq -r '.jobs.quality-checks.steps[] | select(.id == "prepare-bazel-cache") | .if' "$workflow"
  [ "$status" -eq 0 ]
  [[ "$output" == *"steps.inspect-cache.outcome == 'success'"* ]]
  run yq -r '.jobs.quality-checks.steps[] | select(.id == "prepare-bazel-cache") | .run' "$workflow"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--prune-required"* ]]
}

@test "main cache health reports failures without blocking publication jobs" {
  workflow="$BATS_TEST_DIRNAME/../../.github/workflows/publish.yaml"
  run yq -r '.jobs["cache-health"].needs' "$workflow"
  [ "$status" -eq 0 ]
  [ "$output" = "quality-checks" ]
  run yq -r '.jobs["cache-health"].if' "$workflow"
  [ "$status" -eq 0 ]
  [[ "$output" == *"github.event_name == 'push'"* ]]
  [[ "$output" == *"cache_prune_needed == 'true'"* ]]
  run yq -r '.jobs["cache-health"].steps[0].run' "$workflow"
  [ "$status" -eq 0 ]
  [[ "$output" == *"A Bazel cache operation failed."* ]]

  for job in publish-devcontainers publish-release; do
    run env JOB="$job" yq -r '.jobs[strenv(JOB)].needs | join(",")' "$workflow"
    [ "$status" -eq 0 ]
    [[ "$output" != *"cache-health"* ]]
    [[ "$output" == *"quality-checks"* ]]
    [[ "$output" == *"arm64-validation"* ]]
  done
}

@test "cache outcome and health scripts distinguish required, failed and unattempted operations" {
  workflow="$BATS_TEST_DIRNAME/../../.github/workflows/publish.yaml"
  outcome_script="$BATS_TEST_TMPDIR/cache-outcomes.sh"
  health_script="$BATS_TEST_TMPDIR/cache-health.sh"
  run yq -r '.jobs["quality-checks"].steps[] | select(.id == "cache-outcomes") | .run' "$workflow"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$outcome_script"
  run yq -r '.jobs["cache-health"].steps[] | select(.name == "report cache health") | .run' "$workflow"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$health_script"

  outcomes="$BATS_TEST_TMPDIR/cache-outcomes"
  run env \
    RESTORE_OUTCOME=success INSPECT_OUTCOME=success PRUNE_OUTCOME=skipped \
    PREPARE_OUTCOME=success UPLOAD_OUTCOME=success PRUNE_NEEDED=false \
    RESTORE_REASON= INSPECT_REASON= PRUNE_REASON= PREPARE_REASON= \
    GITHUB_OUTPUT="$outcomes" bash "$outcome_script"
  [ "$status" -eq 0 ]
  grep -Fx 'prune_outcome=not-attempted' "$outcomes"
  grep -Fx 'prune_needed=false' "$outcomes"
  run env \
    RESTORE_OUTCOME=success INSPECT_OUTCOME=success PRUNE_OUTCOME=not-attempted \
    PREPARE_OUTCOME=success UPLOAD_OUTCOME=success PRUNE_NEEDED=false \
    FAILURE_REASON= QUALITY_RESULT=success bash "$health_script"
  [ "$status" -eq 0 ]

  run env \
    RESTORE_OUTCOME=success INSPECT_OUTCOME=success PRUNE_OUTCOME=success \
    PREPARE_OUTCOME=success UPLOAD_OUTCOME=success PRUNE_NEEDED=true \
    FAILURE_REASON= QUALITY_RESULT=success bash "$health_script"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cache pruning completed"* ]]

  run env \
    RESTORE_OUTCOME=success INSPECT_OUTCOME=success PRUNE_OUTCOME=not-attempted \
    PREPARE_OUTCOME=success UPLOAD_OUTCOME=not-attempted PRUNE_NEEDED=true \
    FAILURE_REASON= QUALITY_RESULT=success bash "$health_script"
  [ "$status" -eq 1 ]
  [[ "$output" == *"snapshot upload was not successful"* ]]

  run env \
    RESTORE_OUTCOME=failure INSPECT_OUTCOME=success PRUNE_OUTCOME=not-attempted \
    PREPARE_OUTCOME=success UPLOAD_OUTCOME=success PRUNE_NEEDED=false \
    FAILURE_REASON='Cache restore API request failed.' QUALITY_RESULT=success bash "$health_script"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Cache restore API request failed."* ]]

  run env \
    RESTORE_OUTCOME=success INSPECT_OUTCOME=success PRUNE_OUTCOME=not-attempted \
    PREPARE_OUTCOME= UPLOAD_OUTCOME= PRUNE_NEEDED=false \
    FAILURE_REASON= QUALITY_RESULT=success bash "$health_script"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Cache outcomes are missing"* ]]
}

@test "Publish retains rebuild explanations even when Bazel fails" {
  workflow="$BATS_TEST_DIRNAME/../../.github/workflows/publish.yaml"
  slice="$BATS_TEST_TMPDIR/diagnostics-step"
  grep -F "BAZEL_DIAGNOSTICS_DIR: \${{ runner.temp }}/bazel-diagnostics" "$workflow"
  sed -n '/- name: upload Bazel rebuild explanations/,/- name: prepare Bazel cache snapshot/p' "$workflow" > "$slice"
  grep -F 'if: always()' "$slice"
  grep -F 'uses: actions/upload-artifact@v7' "$slice"
  grep -F "path: \${{ runner.temp }}/bazel-diagnostics/*.log" "$slice"
}

@test "Publish uploads both Bazel execution logs even when a build fails" {
  workflow="$BATS_TEST_DIRNAME/../../.github/workflows/publish.yaml"
  step='.jobs.quality-checks.steps[] | select(.name == "upload Bazel execution logs")'

  run yq -r "$step | .if" "$workflow"
  [ "$status" -eq 0 ]
  [ "$output" = 'always()' ]
  run yq -r "$step | .uses" "$workflow"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^actions/upload-artifact@v[0-9]+$ ]]
  run yq -r "$step | .with.path" "$workflow"
  [ "$status" -eq 0 ]
  # shellcheck disable=SC2016
  [ "${lines[0]}" = '${{ runner.temp }}/bazel-format-execution.json' ]
  # shellcheck disable=SC2016
  [ "${lines[1]}" = '${{ runner.temp }}/bazel-check-execution.json' ]
  [ "${#lines[@]}" -eq 2 ]
  run yq -r "$step | .with.if-no-files-found" "$workflow"
  [ "$status" -eq 0 ]
  [ "$output" = ignore ]
}

@test "Publish configures runner-dependent diagnostics only in build step environments" {
  workflow="$BATS_TEST_DIRNAME/../../.github/workflows/publish.yaml"
  run yq '.jobs.quality-checks.env | has("BAZEL_DIAGNOSTICS_DIR")' "$workflow"
  [ "$status" -eq 0 ]
  [ "$output" = false ]

  for step in "check project formatting" "Bazel precommit checks, unit tests, and cacheable validations"; do
    run env STEP="$step" yq -r '.jobs.quality-checks.steps[] | select(.name == strenv(STEP)) | .env.BAZEL_DIAGNOSTICS_DIR' "$workflow"
    [ "$status" -eq 0 ]
    [ "$output" = "\${{ runner.temp }}/bazel-diagnostics" ]
  done
}

@test "cleanup supports scheduled and manual runs only on trusted main with isolated deletion permissions" {
  workflow="$BATS_TEST_DIRNAME/../../.github/workflows/bazel-cache-cleanup.yaml"
  publish="$BATS_TEST_DIRNAME/../../.github/workflows/publish.yaml"
  cleanup="$BATS_TEST_TMPDIR/cleanup-job"
  sed -n '/^  cleanup-bazel-cache:/,$p' "$workflow" > "$cleanup"

  grep -E "cron: ['\"]17 3 \\* \\* \\*['\"]" "$workflow"
  grep -F 'workflow_dispatch:' "$workflow"
  grep -F "if: (github.event_name == 'schedule' || github.event_name == 'workflow_dispatch') && github.ref == 'refs/heads/main'" "$cleanup"
  grep -F 'actions: write' "$cleanup"
  grep -F 'pull-requests: read' "$cleanup"
  grep -F 'python3 .scripts/bazel-cache-artifacts.py cleanup' "$cleanup"
  run grep -F 'schedule:' "$publish"
  [ "$status" -eq 1 ]
  [ "$(grep -c 'actions: write' "$publish")" -eq 0 ]
  grep -F "retention-days: \${{ github.event_name == 'push' && github.ref == 'refs/heads/main' && 90 || 7 }}" "$publish"
}
