#!/usr/bin/env bats

load format-cache-setup

@test "Bazel script-test actions cache unrelated tasks and track their task tool and suite inputs" {
  setup_bazel_fixture

  run script_test_build
  [ "$status" -eq 0 ]
  [ "$(wc -l < test-calls.log)" -eq 1 ]
  run script_test_build
  [ "$status" -eq 0 ]
  [ "$(wc -l < test-calls.log)" -eq 1 ]

  printf '%s\n' '[unrelated]' 'run = "true"' > .mise/tasks/unrelated.toml
  run script_test_build
  [ "$status" -eq 0 ]
  [ "$(wc -l < test-calls.log)" -eq 1 ]

  printf '%s\n' '# unrelated task changed' >> .mise/tasks/project-actions.toml
  run script_test_build
  [ "$status" -eq 0 ]
  [ "$(wc -l < test-calls.log)" -eq 1 ]

  printf '%s\n' '# task changed' >> .mise/tasks/script-tests.toml
  run script_test_build
  [ "$status" -eq 0 ]
  [ "$(wc -l < test-calls.log)" -eq 2 ]

  printf '%s\n' 'formatter = "2"' >> .mise/config.toml
  run script_test_build
  [ "$status" -eq 0 ]
  [ "$(wc -l < test-calls.log)" -eq 3 ]

  printf '%s\n' '# suite input changed' >> .scripts/format-check.sh
  run script_test_build
  [ "$status" -eq 0 ]
  [ "$(wc -l < test-calls.log)" -eq 4 ]
}
