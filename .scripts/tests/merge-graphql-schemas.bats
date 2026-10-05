#!/usr/bin/env bats

load test_helper

setup() {
  setup_fixture merge-graphql-schemas.sh
  mkdir -p mcp .scripts/tests
  cat > mcp/.project.yaml << 'EOF'
---
graphqlSchema: "."
EOF

  setup_mock_bin
  cat > "$FIXTURE_ROOT/bin/mise" << 'EOF'
#!/bin/sh
if [ "$1" = exec ] && [ "$2" = -- ] && [ "$3" = yq ]; then
  printf '%s\n' .
else
  case "$*" in
    "run --raw generate-docker-compose prepare" | "run --raw create-intranet")
      printf '%s\n' "$*" >> "$MOCK_LOG"
      ;;
    *)
      echo "Unexpected mise arguments: $*" >&2
      exit 1
      ;;
  esac
fi
EOF
  cat > "$FIXTURE_ROOT/bin/docker" << 'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$DOCKER_LOG"
case "$*" in
  "compose build graphql") exit "${BUILD_STATUS:-0}" ;;
  "compose run --rm --no-deps --entrypoint /app/graphql graphql print-schema")
    printf '%s\n' 'type Query { ready: Boolean! }'
    exit "${SCHEMA_STATUS:-0}"
    ;;
  *)
    echo "Unexpected docker arguments: $*" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "$FIXTURE_ROOT/bin/mise" "$FIXTURE_ROOT/bin/docker"
  export DOCKER_LOG="$FIXTURE_ROOT/docker.log"
}

@test "generates GraphQL schema from the application image without devcontainers" {
  run sh .scripts/merge-graphql-schemas.sh

  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_LOG")" = $'run --raw generate-docker-compose prepare\nrun --raw create-intranet' ]
  [ "$(cat mcp/recipe-db.graphqls)" = "type Query { ready: Boolean! }" ]
  [ "$(cat "$DOCKER_LOG")" = $'compose build graphql\ncompose run --rm --no-deps --entrypoint /app/graphql graphql print-schema' ]
  [[ $output != *in-devcontainer* ]]
}

@test "application image build failures preserve existing schemas without fallback" {
  printf '%s\n' existing-schema > mcp/recipe-db.graphqls

  run env BUILD_STATUS=19 sh .scripts/merge-graphql-schemas.sh

  [ "$status" -eq 19 ]
  [ "$(cat mcp/recipe-db.graphqls)" = existing-schema ]
  [ "$(cat "$DOCKER_LOG")" = "compose build graphql" ]
}

@test "schema printing failures preserve existing schemas without fallback" {
  printf '%s\n' existing-schema > mcp/recipe-db.graphqls

  run env SCHEMA_STATUS=23 sh .scripts/merge-graphql-schemas.sh

  [ "$status" -eq 23 ]
  [ "$(cat mcp/recipe-db.graphqls)" = existing-schema ]
}
