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
  grep -F 'def union_caches(' "$BATS_TEST_DIRNAME/../bazel-cache-artifacts.py"
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

@test "nightly cleanup is scheduled on trusted main with isolated deletion permissions" {
  workflow="$BATS_TEST_DIRNAME/../../.github/workflows/publish.yaml"
  cleanup="$BATS_TEST_TMPDIR/cleanup-job"
  sed -n '/^  cleanup-bazel-cache:/,$p' "$workflow" > "$cleanup"

  grep -F "cron: '17 3 * * *'" "$workflow"
  grep -F "if: github.event_name == 'schedule' && github.ref == 'refs/heads/main'" "$cleanup"
  grep -F 'actions: write' "$cleanup"
  grep -F 'pull-requests: read' "$cleanup"
  grep -F 'python3 .scripts/bazel-cache-artifacts.py cleanup' "$cleanup"
  grep -F "github.event_name != 'schedule'" "$workflow"
  [ "$(grep -c 'actions: write' "$workflow")" -eq 1 ]
  grep -F "retention-days: \${{ github.event_name == 'push' && github.ref == 'refs/heads/main' && 90 || 7 }}" "$workflow"
}
