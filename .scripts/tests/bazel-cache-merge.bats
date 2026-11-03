#!/usr/bin/env bats

load test_helper

@test "bounded Bazel cache merger validates snapshots and conflict rules" {
  run python3 -B "$BATS_TEST_DIRNAME/../experiments/bazel-cache-merge/test_merge.py"
  [ "$status" -eq 0 ]
}
