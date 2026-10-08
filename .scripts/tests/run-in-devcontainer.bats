#!/usr/bin/env bats

load test_helper

setup() {
  setup_fixture run-in-devcontainer.sh
  setup_mock_bin
  install_mock devcontainer-docker.sh docker
  install_mock devcontainer-cli.sh devcontainer
  mkdir example
  cat > example/.project.yaml << 'EOF'
name: example
---
test: |
  # skip comments and blank lines
  echo first

  echo second
generate:
  - command: echo generated
  - command: echo finished
EOF
}

@test "reuses running containers and keeps lifecycle messages off stdout" {
  run --separate-stderr env -u GITHUB_ACTIONS RUNNING_CONTAINER=running-container sh .scripts/run-in-devcontainer.sh example echo hello

  [ "$status" -eq 0 ]
  [ "$output" = "command output" ]
  [ "$stderr" = "Using existing running container running-container" ]
  grep -Fx "devcontainer exec --container-id running-container --workspace-folder $FIXTURE_ROOT/example fish -c echo hello" "$MOCK_LOG"
  run -1 grep -E '^(devcontainer up|docker (stop|rm))' "$MOCK_LOG"
}

@test "serializes overlapping invocations through container cleanup" {
  gate="$FIXTURE_ROOT/exec-gate"
  env EXEC_GATE="$gate" timeout 10 sh .scripts/run-in-devcontainer.sh example echo first > first.log 2>&1 &
  first_pid=$!
  for _ in {1..100}; do
    [ ! -f "$gate.started" ] || break
    sleep 0.05
  done

  # Hold the first execution while a second invocation tries to discover Docker.
  timeout 10 sh .scripts/run-in-devcontainer.sh example echo second > second.log 2>&1 &
  second_pid=$!
  sleep 0.2
  discoveries=$(grep -c '^docker ps --filter' "$MOCK_LOG")
  touch "$gate.release"
  wait "$first_pid"
  wait "$second_pid"

  [ -f "$gate.started" ]
  [ "$discoveries" -eq 1 ]
  grep -E '^(docker ps --filter|docker stop|devcontainer exec)' "$MOCK_LOG" > lifecycle.log
  cat > expected.log << EOF
docker ps --filter label=devcontainer.config_file=$FIXTURE_ROOT/example/.devcontainer/devcontainer.json --format {{.ID}}
devcontainer exec --container-id started-container --workspace-folder $FIXTURE_ROOT/example fish -c echo first
docker stop started-container
docker ps --filter label=devcontainer.config_file=$FIXTURE_ROOT/example/.devcontainer/devcontainer.json --format {{.ID}}
devcontainer exec --container-id started-container --workspace-folder $FIXTURE_ROOT/example fish -c echo second
docker stop started-container
EOF
  diff -u expected.log lifecycle.log
}

@test "different projects do not share a lifecycle lock" {
  mkdir another
  cp example/.project.yaml another/.project.yaml
  mkdir -p example/.devcontainer
  exec 8> example/.devcontainer/.lifecycle.lock
  flock -x 8

  run timeout 5 sh .scripts/run-in-devcontainer.sh another echo hello

  [ "$status" -eq 0 ]
  grep -Fx "devcontainer exec --container-id started-container --workspace-folder $FIXTURE_ROOT/another fish -c echo hello" "$MOCK_LOG"
}

@test "restarts stopped containers and stops them after successful commands" {
  export STOPPED_CONTAINER=stopped-container

  run sh .scripts/run-in-devcontainer.sh example test

  [ "$status" -eq 0 ]
  [[ "$output" == *"Starting existing stopped container stopped-container"* ]]
  grep -Fx "devcontainer up --workspace-folder $FIXTURE_ROOT/example" "$MOCK_LOG"
  grep -Fx "devcontainer exec --container-id started-container --workspace-folder $FIXTURE_ROOT/example fish -c echo first && echo second" "$MOCK_LOG"
  [ "$(tail -n 1 "$MOCK_LOG")" = "docker stop started-container" ]
}

@test "new containers are stopped while command failures retain their exit status" {
  export EXEC_STATUS=17

  run sh .scripts/run-in-devcontainer.sh example echo failing

  [ "$status" -eq 17 ]
  [ "$(tail -n 1 "$MOCK_LOG")" = "docker stop started-container" ]
}

@test "rm works before or after the project and removes even running containers" {
  for position in before after; do
    : > "$MOCK_LOG"
    if [ "$position" = before ]; then
      run env RUNNING_CONTAINER=running-container sh .scripts/run-in-devcontainer.sh --rm example echo hello
    else
      run env RUNNING_CONTAINER=running-container sh .scripts/run-in-devcontainer.sh example --rm echo hello
    fi

    [ "$status" -eq 0 ]
    [ "$(tail -n 1 "$MOCK_LOG")" = "docker rm -f running-container" ]
    run -1 grep -F 'docker stop' "$MOCK_LOG"
  done
}

@test "joins generator commands from the second YAML document" {
  run env RUNNING_CONTAINER=running-container sh .scripts/run-in-devcontainer.sh example generate

  [ "$status" -eq 0 ]
  grep -Fx "devcontainer exec --container-id running-container --workspace-folder $FIXTURE_ROOT/example fish -c echo generated && echo finished" "$MOCK_LOG"
}

@test "rejects missing commands, unknown projects and undefined targets before Docker calls" {
  run --separate-stderr sh .scripts/run-in-devcontainer.sh example
  [ "$status" -eq 1 ]
  [ "$stderr" = "Missing command" ]

  run --separate-stderr sh .scripts/run-in-devcontainer.sh missing test
  [ "$status" -eq 1 ]
  [ "$stderr" = "Project missing is missing" ]

  run --separate-stderr sh .scripts/run-in-devcontainer.sh example check
  [ "$status" -eq 1 ]
  [ "$stderr" = "Project does not have check command" ]
  [ ! -s "$MOCK_LOG" ]
}

@test "rejects project paths rather than subproject names" {
  for project in '' . .. ../example example/nested; do
    run --separate-stderr sh .scripts/run-in-devcontainer.sh "$project" test

    [ "$status" -eq 1 ]
    [ "$stderr" = "Expected a subproject name" ]
    [ ! -s "$MOCK_LOG" ]
  done
}

@test "cleanup failure makes an otherwise successful invocation fail" {
  export CLEANUP_STATUS=1

  run sh .scripts/run-in-devcontainer.sh example test

  [ "$status" -eq 1 ]
  [ "$(tail -n 1 "$MOCK_LOG")" = "docker stop started-container" ]
}

@test "container startup failure does not execute commands" {
  export UP_STATUS=23

  run sh .scripts/run-in-devcontainer.sh example test

  [ "$status" -eq 23 ]
  run -1 grep -F 'devcontainer exec' "$MOCK_LOG"
}

@test "Docker discovery failures stop before startup or execution" {
  run --separate-stderr env -u GITHUB_ACTIONS PS_STATUS=24 sh .scripts/run-in-devcontainer.sh example test

  [ "$status" -eq 24 ]
  [ "$stderr" = "Docker discovery failed" ]
  run -1 grep -F 'devcontainer ' "$MOCK_LOG"
}

@test "missing container IDs are rejected before execution" {
  run env UP_JSON='{}' sh .scripts/run-in-devcontainer.sh example test

  [ "$status" -ne 0 ]
  run -1 grep -F 'devcontainer exec' "$MOCK_LOG"
}
