#!/usr/bin/env bats

load format-cache-setup

@test "Bazel format checks invalidate on relevant tasks and tool configuration" {
  setup_cached_formats
  check_format_invalidations unrelated_task unrelated_task_change relevant_task tool_config
}
