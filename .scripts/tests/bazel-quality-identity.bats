#!/usr/bin/env bats

load test_helper

setup() {
  setup_fixture bazel-quality-identity.sh
  setup_mock_bin
  cat > bin/mise << 'EOF'
#!/bin/sh
case "$*" in
  "ls --json")
    printf '{"fixture":[{"active":true,"version":"%s","requested_version":"latest","installed":true,"install_path":"/private/path"}]}\n' "${TOOL_VERSION:-1.0}"
    ;;
  --version) printf '%s\n' 'mise 2026.1' ;;
  *) exit 99 ;;
esac
EOF
  cat > bin/docker << 'EOF'
#!/bin/sh
case "$*" in
  --version) printf '%s\n' 'Docker version 29.0' ;;
  "info --format {{.ServerVersion}}")
    [ "${DOCKER_INFO_STATUS:-0}" = 0 ] || exit "$DOCKER_INFO_STATUS"
    printf '%s\n' 29.0
    ;;
  "inspect --format {{.Image}} container-id") printf '%s\n' "${IMAGE_ID-sha256:image-one}" ;;
  "image inspect --format {{.Os}}/{{.Architecture}} sha256:image-one") printf '%s\n' linux/amd64 ;;
  "image inspect --format {{.Os}}/{{.Architecture}} sha256:image-two") printf '%s\n' linux/arm64 ;;
  *) exit 99 ;;
esac
EOF
  chmod +x bin/mise bin/docker
  mkdir -p example/.devcontainer
  cat > example/.devcontainer/devcontainer.json << 'EOF'
{
  "image": "example:latest",
  "build": {"context": "..", "dockerfile": "Dockerfile"},
  "features": {"example/tool": {"version": "1.2.3"}},
  "containerEnv": {"TOKEN": "do-not-hash"}
}
EOF
}

@test "host identity lookup failures are not masked by formatting" {
  run env DOCKER_INFO_STATUS=23 sh .scripts/bazel-quality-identity.sh host

  [ "$status" -eq 23 ]
  [ ! -e .generated/bazel-quality/host.identity ]
}

@test "host identity tracks selected tool versions without private paths and keeps stable output unchanged" {
  run sh .scripts/bazel-quality-identity.sh host

  [ "$status" -eq 0 ]
  identity=.generated/bazel-quality/host.identity
  first=$(cat "$identity")
  [[ "$first" == *'version":"1.0"'* ]]
  [[ "$first" != *'/private/path'* ]]
  inode=$(stat -c %i "$identity")

  run sh .scripts/bazel-quality-identity.sh host

  [ "$status" -eq 0 ]
  [ "$(stat -c %i "$identity")" = "$inode" ]

  run env TOOL_VERSION=2.0 sh .scripts/bazel-quality-identity.sh host

  [ "$status" -eq 0 ]
  [ "$(cat "$identity")" != "$first" ]
}

@test "project identity tracks the selected container image and excludes container environment values" {
  run sh .scripts/bazel-quality-identity.sh example container-id

  [ "$status" -eq 0 ]
  identity=.generated/bazel-quality/example.identity
  first=$(cat "$identity")
  [[ "$first" == *'sha256:image-one'* ]]
  [[ "$first" != *'do-not-hash'* ]]
  inode=$(stat -c %i "$identity")

  run sh .scripts/bazel-quality-identity.sh example container-id

  [ "$status" -eq 0 ]
  [ "$(stat -c %i "$identity")" = "$inode" ]

  before_config_change=$(cat "$identity")
  sed -i 's/"version": "1.2.3"/"version": "1.2.4"/' example/.devcontainer/devcontainer.json
  run sh .scripts/bazel-quality-identity.sh example container-id

  [ "$status" -eq 0 ]
  [ "$(cat "$identity")" != "$before_config_change" ]

  run env IMAGE_ID=sha256:image-two sh .scripts/bazel-quality-identity.sh example container-id

  [ "$status" -eq 0 ]
  [[ "$(cat "$identity")" == *'linux/arm64'* ]]
  [[ "$(cat "$identity")" == *'sha256:image-two'* ]]
}

@test "project identity fails visibly when the selected runtime cannot be resolved" {
  run --separate-stderr env IMAGE_ID= sh .scripts/bazel-quality-identity.sh example container-id

  [ "$status" -eq 1 ]
  [ "$stderr" = "Could not resolve image identity for container container-id" ]
}
