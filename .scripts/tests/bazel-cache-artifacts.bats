#!/usr/bin/env bats

load test_helper

@test "Bazel cache artifact selection and intake tests pass" {
  run env PYTHONDONTWRITEBYTECODE=1 python3 "$BATS_TEST_DIRNAME/bazel-cache-artifacts.py"

  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "Publish restores, validates and uploads Bazel snapshots before integration" {
  workflow="$BATS_TEST_DIRNAME/../../.github/workflows/publish.yaml"
  restore=$(grep -n '^      - name: restore and union Bazel disk cache artifacts$' "$workflow" | cut -d: -f1)
  format=$(grep -n '^      - name: check project formatting$' "$workflow" | cut -d: -f1)
  checks=$(grep -n '^      - name: Bazel precommit checks and unit tests$' "$workflow" | cut -d: -f1)
  prepare=$(grep -n '^      - name: prepare Bazel cache snapshot$' "$workflow" | cut -d: -f1)
  upload=$(grep -n '^      - name: upload Bazel cache snapshot$' "$workflow" | cut -d: -f1)
  integration=$(grep -n '^      - name: validate message bus integration and recovery$' "$workflow" | cut -d: -f1)

  [ "$restore" -lt "$format" ]
  [ "$format" -lt "$checks" ]
  [ "$checks" -lt "$prepare" ]
  [ "$prepare" -lt "$upload" ]
  [ "$upload" -lt "$integration" ]
  grep -F 'actions: read' "$workflow"
  grep -F 'fetch-depth: 0' "$workflow"
  grep -F -- "--run-number \"\$GITHUB_RUN_NUMBER\"" "$workflow"
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

  run yq -r '.jobs.publish.steps[] | select(.name == "checkout") | .with.ref' "$workflow"
  [ "$status" -eq 0 ]
  [ "$output" = '${{ github.sha }}' ]
  run grep -F -- '--commit "${{ steps.source.outputs.sha }}"' "$workflow"
  [ "$status" -eq 0 ]
  run grep -F '"$GITHUB_SHA"' "$workflow"
  [ "$status" -eq 1 ]
}

@test "Bazel snapshot upload depends on both completed Bazel stages" {
  workflow="$BATS_TEST_DIRNAME/../../.github/workflows/publish.yaml"
  slice="$BATS_TEST_TMPDIR/workflow-slice"
  sed -n '/- name: check project formatting/,/- name: validate message bus integration/p' "$workflow" > "$slice"

  grep -F -- "--execution_log_json_file=\"\$RUNNER_TEMP/bazel-format-execution.json\"" "$slice"
  grep -F -- "--execution_log_json_file=\"\$RUNNER_TEMP/bazel-check-execution.json\"" "$slice"
  grep -F 'steps.prepare-bazel-cache.outputs.name' "$slice"
  grep -F 'if: success()' "$slice"
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

@test "Publish configures runner-dependent diagnostics only in build step environments" {
  workflow="$BATS_TEST_DIRNAME/../../.github/workflows/publish.yaml"
  run yq '.jobs.quality-checks.env | has("BAZEL_DIAGNOSTICS_DIR")' "$workflow"
  [ "$status" -eq 0 ]
  [ "$output" = false ]

  for step in "check project formatting" "Bazel precommit checks and unit tests"; do
    run env STEP="$step" yq -r '.jobs.quality-checks.steps[] | select(.name == strenv(STEP)) | .env.BAZEL_DIAGNOSTICS_DIR' "$workflow"
    [ "$status" -eq 0 ]
    [ "$output" = "\${{ runner.temp }}/bazel-diagnostics" ]
  done
}

@test "nightly cleanup is scheduled on trusted main with isolated deletion permissions" {
  workflow="$BATS_TEST_DIRNAME/../../.github/workflows/bazel-cache-cleanup.yaml"
  publish="$BATS_TEST_DIRNAME/../../.github/workflows/publish.yaml"
  cleanup="$BATS_TEST_TMPDIR/cleanup-job"
  sed -n '/^  cleanup-bazel-cache:/,$p' "$workflow" > "$cleanup"

  grep -E "cron: ['\"]17 3 \\* \\* \\*['\"]" "$workflow"
  grep -F "if: github.event_name == 'schedule' && github.ref == 'refs/heads/main'" "$cleanup"
  grep -F 'actions: write' "$cleanup"
  grep -F 'pull-requests: read' "$cleanup"
  grep -F 'python3 .scripts/bazel-cache-artifacts.py cleanup' "$cleanup"
  run grep -F 'schedule:' "$publish"
  [ "$status" -eq 1 ]
  [ "$(grep -c 'actions: write' "$publish")" -eq 0 ]
  grep -F "retention-days: \${{ github.event_name == 'push' && github.ref == 'refs/heads/main' && 90 || 7 }}" "$publish"
}
