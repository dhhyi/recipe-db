#!/usr/bin/env bats

load test_helper

setup() {
  setup_fixture check-forbidden-files.sh
  git init -q
}

@test "allows root and project gitignores" {
  mkdir -p example
  touch .gitignore example/.gitignore example/.project.yaml
  git add -f .gitignore example/.gitignore example/.project.yaml

  run sh .scripts/check-forbidden-files.sh

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "reports both kinds of forbidden tracked files on stderr" {
  mkdir -p nested example
  touch nested/.gitignore example/.project.yaml example/.prettierignore
  git add -f nested/.gitignore example/.project.yaml example/.prettierignore

  run --separate-stderr sh .scripts/check-forbidden-files.sh

  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = $'Forbidden .gitignore files found: nested/.gitignore\nForbidden files found: example/.prettierignore' ]
}

@test "ignores forbidden files that are not tracked" {
  mkdir -p nested
  touch nested/.gitignore nested/.prettierignore

  run sh .scripts/check-forbidden-files.sh

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
