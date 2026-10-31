#!/usr/bin/env bats

load test_helper

setup() {
  setup_fixture bazel-quality.sh
  setup_mock_bin
  cat > .scripts/bazel-quality-identity.sh <<'EOF'
#!/bin/sh
printf 'identity %s\n' "$*" >> "$MOCK_LOG"
EOF
  cat > bin/mise <<'EOF'
#!/bin/sh
printf 'mise %s identity=%s\n' "$*" "${BAZEL_QUALITY_IDENTITY:-}" >> "$MOCK_LOG"
case "$*" in
  'exec -- yq '*) shift 2; exec "$@" ;;
  'run --raw create-intranet' | 'run --raw in-devcontainer '* | 'run --raw generate-bazel-build') ;;
  'run --raw bazel build '* ) exit "${BAZEL_STATUS:-0}" ;;
  *) echo "Unexpected mise invocation: $*" >&2; exit 99 ;;
esac
EOF
  chmod +x bin/mise
  for project in example check-only generated-only; do
    mkdir -p "$project"
    printf 'name: %s\n---\n' "$project" > "$project/.project.yaml"
  done
  cat >> example/.project.yaml <<'EOF'
check: echo checked
generate:
  - command: echo generated
format: echo formatted
EOF
  cat >> check-only/.project.yaml <<'EOF'
check: echo checked
EOF
  cat >> generated-only/.project.yaml <<'EOF'
generate:
  - command: echo generated
format: echo formatted
EOF
  touch mise.toml .bazelversion
}

@test "quality prepares each project once, resolves identities, and builds only the aggregate" {
  run env CI=true GITHUB_ACTIONS=true COMPOSE_PARALLEL_LIMIT=1 DEVCONTAINER_KEEP_RUNNING=true \
    bash .scripts/bazel-quality.sh

  [ "$status" -eq 0 ]
  cat > expected-calls <<EOF
mise run --raw create-intranet identity=
mise run --raw in-devcontainer check-only true identity=1
mise run --raw in-devcontainer example prepare identity=1
mise run --raw in-devcontainer generated-only prepare identity=1
identity host
mise run --raw generate-bazel-build identity=
mise run --raw bazel build --action_env=PATH --action_env=CI --action_env=GITHUB_ACTIONS --action_env=COMPOSE_PARALLEL_LIMIT --action_env=DEVCONTAINER_KEEP_RUNNING --jobs=1 --disk_cache=$HOME/.cache/bazel-disk //:quality identity=
EOF
  cmp expected-calls "$MOCK_LOG"
}

@test "quality propagates aggregate failures" {
  run env BAZEL_STATUS=23 bash .scripts/bazel-quality.sh

  [ "$status" -eq 23 ]
}
