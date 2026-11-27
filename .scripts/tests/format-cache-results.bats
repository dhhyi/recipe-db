#!/usr/bin/env bats

load format-cache-setup

@test "Bazel rejects unformatted files without mutations then caches the formatted state" {
  setup_bazel_fixture
  printf '%s\n' unformatted > example/main.txt

  run format_build

  [ "$status" -ne 0 ]
  [[ "$output" == *"PROJECT_FORMAT_UNFORMATTED:example"* ]]
  [ "$(cat example/main.txt)" = unformatted ]

  printf '%s\n' formatted > example/main.txt
  run format_build
  [ "$status" -eq 0 ]
  before=$(grep -c '^check:example' check-calls.log)
  run format_build
  [ "$status" -eq 0 ]
  [ "$(grep -c '^check:example' check-calls.log)" -eq "$before" ]
}

@test "successful format checks are restored from disk cache after cleaning outputs" {
  setup_bazel_fixture
  run format_build --disk_cache="$BATS_TEST_TMPDIR/disk-cache"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^check:' check-calls.log)" -eq 2 ]

  run bash .scripts/bazel.sh --batch --output_base="$BATS_TEST_TMPDIR/bazel" clean
  [ "$status" -eq 0 ]

  run format_build --disk_cache="$BATS_TEST_TMPDIR/disk-cache"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^check:' check-calls.log)" -eq 2 ]
}
