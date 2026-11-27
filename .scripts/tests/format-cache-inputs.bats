#!/usr/bin/env bats

load format-cache-setup

@test "Bazel format checks invalidate only affected project inputs" {
  setup_cached_formats
  check_format_invalidations source addition removal config command tool
}
