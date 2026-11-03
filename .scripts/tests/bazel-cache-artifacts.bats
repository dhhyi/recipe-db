#!/usr/bin/env bats

load test_helper

@test "Bazel cache artifact selection and intake tests pass" {
  run env PYTHONDONTWRITEBYTECODE=1 python3 "$BATS_TEST_DIRNAME/bazel-cache-artifacts.py"

  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "Publish restores, validates and uploads Bazel snapshots before integration" {
  workflow="$BATS_TEST_DIRNAME/../../.github/workflows/publish.yaml"
  restore=$(grep -n '^      - name: restore Bazel disk cache artifact$' "$workflow" | cut -d: -f1)
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
  grep -F "retention-days: \${{ github.event_name == 'push' && github.ref == 'refs/heads/main' && 90 || 7 }}" "$workflow"
  ! grep -F 'uses: actions/cache@' "$workflow"
  grep -F 'continue-on-error: true' "$workflow"
}

@test "Bazel snapshot upload depends on both completed Bazel stages" {
  workflow="$BATS_TEST_DIRNAME/../../.github/workflows/publish.yaml"
  slice="$BATS_TEST_TMPDIR/workflow-slice"
  sed -n '/- name: check project formatting/,/- name: validate message bus integration/p' "$workflow" > "$slice"

  grep -F -- '--execution_log_json_file="$RUNNER_TEMP/bazel-format-execution.json"' "$slice"
  grep -F -- '--execution_log_json_file="$RUNNER_TEMP/bazel-check-execution.json"' "$slice"
  grep -F 'steps.prepare-bazel-cache.outputs.name' "$slice"
  grep -F 'if: success()' "$slice"
}
