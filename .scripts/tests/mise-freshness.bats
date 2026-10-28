#!/usr/bin/env bats

load test_helper

setup() {
  setup_fixture generate-docker-compose.sh
  root=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  cp "$BATS_TEST_DIRNAME/../"*.sh .scripts/
  mkdir -p .scripts/lib
  cp "$BATS_TEST_DIRNAME/../lib/project-metadata.sh" .scripts/lib/
  cp -R "$BATS_TEST_DIRNAME/../templates" .scripts/
  yq -p toml -o toml 'del(.hooks)' "$root/mise.toml" > mise.toml
  export MISE_TRUSTED_CONFIG_PATHS="$FIXTURE_ROOT:$root"
  export MISE_STATE_DIR="$BATS_TEST_TMPDIR/mise-state"
  export MISE_TASK_RUN_AUTO_INSTALL=false
  export SCHEMA_TEXT='type Query { fixture: Boolean! }'
  printf '%s\n' '{"repository":"github:example/fixture"}' > package.json

  mkdir -p fixtures graphql/src mcp
  cat > fixtures/.project.yaml << 'EOF'
devcontainer:
  ports: [80]
traefik: {}
---
category: static
EOF
  cat > graphql/.project.yaml << 'EOF'
devcontainer:
  ports: [4000]
traefik: {}
---
category: api
EOF
  cat > mcp/.project.yaml << 'EOF'
category: utility
---
graphqlSchema: "."
EOF
  printf '%s\n' 'FROM scratch' > graphql/Dockerfile
  printf '%s\n' 'target' > graphql/.dockerignore
  printf '%s\n' '[package]' > graphql/Cargo.toml
  printf '%s\n' 'version = 4' > graphql/Cargo.lock
  printf '%s\n' 'fn main() {}' > graphql/src/main.rs
  setup_mock_bin
  actual_uid=$(command id -u)
  actual_gid=$(command id -g)
  cat > bin/id << EOF
#!/bin/sh
case "\$1" in
  -u) printf '%s\\n' "\${FAKE_UID:-$actual_uid}" ;;
  -g) printf '%s\\n' "\${FAKE_GID:-$actual_gid}" ;;
  *) exit 2 ;;
esac
EOF
  cat > bin/docker << 'EOF'
#!/bin/sh
case "$*" in
  "network inspect intranet") exit "${NETWORK_INSPECT_STATUS:-0}" ;;
  "network create intranet") exit "${NETWORK_CREATE_STATUS:-0}" ;;
  "compose build graphql")
    printf '%s\n' build >> "$DOCKER_LOG"
    exit "${BUILD_STATUS:-0}"
    ;;
  "run --rm --entrypoint /app/graphql ghcr.io/dhhyi/recipe-db-graphql:latest print-schema")
    printf '%s\n' print >> "$DOCKER_LOG"
    printf '%s\n' "$SCHEMA_TEXT"
    exit "${SCHEMA_STATUS:-0}"
    ;;
  "compose up -d --wait"*)
    test -s docker-compose.yml || exit 1
    printf '%s\n' up >> "$DOCKER_LOG"
    exit "${UP_STATUS:-0}"
    ;;
  *)
    echo "Unexpected docker arguments" >&2
    exit 1
    ;;
esac
EOF
  chmod +x bin/id bin/docker
  export DOCKER_LOG="$FIXTURE_ROOT/docker.log"
  : > "$DOCKER_LOG"
}

@test "Compose freshness refreshes effective inputs, repairs outputs, and runs prerequisites on cache hits" {
  run mise -C "$FIXTURE_ROOT" run --raw generate-docker-compose
  [ "$status" -eq 0 ]
  [[ "$output" == *"Rendering"* ]]
  [ -s docker-compose.yml ]
  [ -s oauth2-proxy-alpha.yml ]
  jq -e 'keys == ["developmentUser","googleOAuthClientId","registryCacheSuffix"]' .generated/compose-inputs.json

  compose_mtime=$(stat -c %y docker-compose.yml)
  oauth_mtime=$(stat -c %y oauth2-proxy-alpha.yml)
  run mise -C "$FIXTURE_ROOT" run --raw generate-docker-compose
  [ "$status" -eq 0 ]
  [[ "$output" != *"Rendering"* ]]
  [ "$(stat -c %y docker-compose.yml)" = "$compose_mtime" ]
  [ "$(stat -c %y oauth2-proxy-alpha.yml)" = "$oauth_mtime" ]

  rm .secrets/typesense-api-key
  run env CI=true VERBOSE=true mise -C "$FIXTURE_ROOT" run --raw generate-docker-compose
  [ "$status" -eq 0 ]
  [[ "$output" != *"Rendering"* ]]
  [ -s .secrets/typesense-api-key ]
  [ "$(stat -c %y docker-compose.yml)" = "$compose_mtime" ]

  run env REGISTRY_CACHE_SUFFIX=-arm64 mise -C "$FIXTURE_ROOT" run --raw generate-docker-compose
  [ "$status" -eq 0 ]
  [[ "$output" == *"Rendering"* ]]
  mise -C "$FIXTURE_ROOT" exec -- yq -e '.services.graphql.build.cache_from[0] | contains("-cache-arm64")' docker-compose.yml

  run env GOOGLE_OAUTH_CLIENT_ID=fixture-client mise -C "$FIXTURE_ROOT" run --raw generate-docker-compose
  [ "$status" -eq 0 ]
  mise -C "$FIXTURE_ROOT" exec -- yq -e '.providers[0].clientID == "fixture-client"' oauth2-proxy-alpha.yml
  run env GOOGLE_OAUTH_CLIENT_ID= mise -C "$FIXTURE_ROOT" run --raw generate-docker-compose
  [ "$status" -eq 0 ]
  mise -C "$FIXTURE_ROOT" exec -- yq -e '.providers[0].clientID == "replace-with-google-oauth-client-id"' oauth2-proxy-alpha.yml

  run env FAKE_UID=1111 FAKE_GID=2222 mise -C "$FIXTURE_ROOT" run --raw generate-docker-compose
  [ "$status" -eq 0 ]
  mise -C "$FIXTURE_ROOT" exec -- yq -e '.services["oauth2-proxy"].user == "1111:2222"' docker-compose.yml

  run mise -C "$FIXTURE_ROOT" run --raw generate-docker-compose
  [ "$status" -eq 0 ]
  [[ "$output" == *"Rendering"* ]]
  mise -C "$FIXTURE_ROOT" exec -- yq -e '.services["oauth2-proxy"].user == "'"$(command id -u):$(command id -g)"'"' docker-compose.yml
}

@test "Mise detects equal-timestamp source edits, output damage, and project additions or removals" {
  run mise -C "$FIXTURE_ROOT" run --raw generate-docker-compose
  [ "$status" -eq 0 ]

  printf '\n#! changed template\n' >> .scripts/templates/nats-service-template.lib.yml
  touch -d @1000000000 .scripts/templates/nats-service-template.lib.yml
  run mise -C "$FIXTURE_ROOT" run --raw generate-docker-compose
  [ "$status" -eq 0 ]
  [[ "$output" == *"Rendering"* ]]

  printf '\n# damaged output\n' >> docker-compose.yml
  run mise -C "$FIXTURE_ROOT" run --raw generate-docker-compose
  [ "$status" -eq 0 ]
  [[ "$output" == *"Rendering"* ]]
  run grep -F 'damaged output' docker-compose.yml
  [ "$status" -eq 1 ]

  mkdir new-service
  cat > new-service/.project.yaml << 'EOF'
devcontainer:
  ports: [8000]
traefik: {}
---
category: backend
EOF
  touch -d @1000000000 new-service/.project.yaml
  run mise -C "$FIXTURE_ROOT" run --raw generate-docker-compose
  [ "$status" -eq 0 ]
  [[ "$output" == *"Rendering"* ]]
  mise -C "$FIXTURE_ROOT" exec -- yq -e '.services["new-service"] != null' docker-compose.yml

  rm new-service/.project.yaml
  run mise -C "$FIXTURE_ROOT" run --raw generate-docker-compose
  [ "$status" -eq 0 ]
  [[ "$output" == *"Rendering"* ]]
  run mise -C "$FIXTURE_ROOT" exec -- yq -e '.services | has("new-service")' docker-compose.yml
  [ "$status" -eq 1 ]
}

@test "Mise detects equal-size Compose source edits with the exact original mtime" {
  run mise -C "$FIXTURE_ROOT" run --raw --force generate-docker-compose
  [ "$status" -eq 0 ]

  source=.scripts/templates/nats-service-template.lib.yml
  cp -p "$source" original-source
  original_size=$(stat -c %s "$source")
  original_mtime=$(stat -c %y "$source")
  sed -i 's/2\.11\.10/2.11.11/' "$source"
  [ "$(stat -c %s "$source")" -eq "$original_size" ]
  touch -r original-source "$source"
  [ "$(stat -c %y "$source")" = "$original_mtime" ]

  run mise -C "$FIXTURE_ROOT" run --raw generate-docker-compose
  [ "$status" -eq 0 ]
  [[ "$output" == *"Rendering"* ]]
  mise -C "$FIXTURE_ROOT" exec -- yq -e '.services.nats.image == "nats:2.11.11-alpine"' docker-compose.yml
}

@test "Mise repairs equal-size Compose and SDL output edits with the exact original mtime" {
  run mise -C "$FIXTURE_ROOT" run --raw --force generate-docker-compose
  [ "$status" -eq 0 ]

  cp -p docker-compose.yml original-compose
  original_size=$(stat -c %s docker-compose.yml)
  original_mtime=$(stat -c %y docker-compose.yml)
  sed -i 's/traefik:v3\.7/traefik:v3.8/' docker-compose.yml
  [ "$(stat -c %s docker-compose.yml)" -eq "$original_size" ]
  touch -r original-compose docker-compose.yml
  [ "$(stat -c %y docker-compose.yml)" = "$original_mtime" ]
  run mise -C "$FIXTURE_ROOT" run --raw generate-docker-compose
  [ "$status" -eq 0 ]
  run grep -F 'traefik:v3.8' docker-compose.yml
  [ "$status" -eq 1 ]

  cp -p oauth2-proxy-alpha.yml original-oauth
  original_size=$(stat -c %s oauth2-proxy-alpha.yml)
  original_mtime=$(stat -c %y oauth2-proxy-alpha.yml)
  sed -i 's/replace-with-google-oauth-client-id/replace-with-google-oauth-client-zz/' oauth2-proxy-alpha.yml
  [ "$(stat -c %s oauth2-proxy-alpha.yml)" -eq "$original_size" ]
  touch -r original-oauth oauth2-proxy-alpha.yml
  [ "$(stat -c %y oauth2-proxy-alpha.yml)" = "$original_mtime" ]
  run mise -C "$FIXTURE_ROOT" run --raw generate-docker-compose
  [ "$status" -eq 0 ]
  [[ "$output" == *"Rendering"* ]]
  mise -C "$FIXTURE_ROOT" exec -- yq -e '.providers[0].clientID == "replace-with-google-oauth-client-id"' oauth2-proxy-alpha.yml

  run mise -C "$FIXTURE_ROOT" run --raw --force merge-graphql-schemas
  [ "$status" -eq 0 ]
  cp -p .generated/graphql/recipe-db.graphqls original-schema
  original_size=$(stat -c %s .generated/graphql/recipe-db.graphqls)
  original_mtime=$(stat -c %y .generated/graphql/recipe-db.graphqls)
  sed -i 's/fixture/feature/' .generated/graphql/recipe-db.graphqls
  [ "$(stat -c %s .generated/graphql/recipe-db.graphqls)" -eq "$original_size" ]
  touch -r original-schema .generated/graphql/recipe-db.graphqls
  [ "$(stat -c %y .generated/graphql/recipe-db.graphqls)" = "$original_mtime" ]
  : > "$DOCKER_LOG"
  run mise -C "$FIXTURE_ROOT" run --raw merge-graphql-schemas
  [ "$status" -eq 0 ]
  [ "$(cat "$DOCKER_LOG")" = $'build\nprint' ]
  cmp .generated/graphql/recipe-db.graphqls mcp/recipe-db.graphqls
}

@test "schema export is cached separately from dynamic consumer distribution" {
  run mise -C "$FIXTURE_ROOT" run --raw merge-graphql-schemas
  [ "$status" -eq 0 ]
  [ "$(cat "$DOCKER_LOG")" = $'build\nprint' ]
  cmp .generated/graphql/recipe-db.graphqls mcp/recipe-db.graphqls

  canonical_mtime=$(stat -c %y .generated/graphql/recipe-db.graphqls)
  : > "$DOCKER_LOG"
  run mise -C "$FIXTURE_ROOT" run --raw merge-graphql-schemas
  [ "$status" -eq 0 ]
  [ ! -s "$DOCKER_LOG" ]
  [ "$(stat -c %y .generated/graphql/recipe-db.graphqls)" = "$canonical_mtime" ]

  printf '%s\n' edited > mcp/recipe-db.graphqls
  : > "$DOCKER_LOG"
  run mise -C "$FIXTURE_ROOT" run --raw merge-graphql-schemas
  [ "$status" -eq 0 ]
  cmp .generated/graphql/recipe-db.graphqls mcp/recipe-db.graphqls
  [ ! -s "$DOCKER_LOG" ]

  mkdir new-consumer
  cat > new-consumer/.project.yaml << 'EOF'
category: utility
---
graphqlSchema: "schema"
EOF
  run mise -C "$FIXTURE_ROOT" run --raw merge-graphql-schemas
  [ "$status" -eq 0 ]
  cmp .generated/graphql/recipe-db.graphqls new-consumer/schema/recipe-db.graphqls

  : > "$DOCKER_LOG"
  rm .generated/graphql/recipe-db.graphqls
  run mise -C "$FIXTURE_ROOT" run --raw merge-graphql-schemas
  [ "$status" -eq 0 ]
  [ "$(cat "$DOCKER_LOG")" = $'build\nprint' ]

  : > "$DOCKER_LOG"
  run mise -C "$FIXTURE_ROOT" run --raw --force merge-graphql-schemas
  [ "$status" -eq 0 ]
  [ "$(cat "$DOCKER_LOG")" = $'build\nprint' ]
}

@test "Mise detects equal-size GraphQL edits and SDL damage with the exact original mtime" {
  run mise -C "$FIXTURE_ROOT" run --raw --force merge-graphql-schemas
  [ "$status" -eq 0 ]
  [ "$(cat "$DOCKER_LOG")" = $'build\nprint' ]

  source=graphql/src/main.rs
  cp -p "$source" original-source
  original_size=$(stat -c %s "$source")
  original_mtime=$(stat -c %y "$source")
  sed -i 's/main/test/' "$source"
  [ "$(stat -c %s "$source")" -eq "$original_size" ]
  touch -r original-source "$source"
  [ "$(stat -c %y "$source")" = "$original_mtime" ]

  : > "$DOCKER_LOG"
  run mise -C "$FIXTURE_ROOT" run --raw merge-graphql-schemas
  [ "$status" -eq 0 ]
  [ "$(cat "$DOCKER_LOG")" = $'build\nprint' ]

  cp -p .generated/graphql/recipe-db.graphqls original-schema
  original_size=$(stat -c %s .generated/graphql/recipe-db.graphqls)
  original_mtime=$(stat -c %y .generated/graphql/recipe-db.graphqls)
  sed -i 's/fixture/feature/' .generated/graphql/recipe-db.graphqls
  [ "$(stat -c %s .generated/graphql/recipe-db.graphqls)" -eq "$original_size" ]
  touch -r original-schema .generated/graphql/recipe-db.graphqls
  [ "$(stat -c %y .generated/graphql/recipe-db.graphqls)" = "$original_mtime" ]

  : > "$DOCKER_LOG"
  run mise -C "$FIXTURE_ROOT" run --raw merge-graphql-schemas
  [ "$status" -eq 0 ]
  [ "$(cat "$DOCKER_LOG")" = $'build\nprint' ]
  cmp .generated/graphql/recipe-db.graphqls mcp/recipe-db.graphqls
}

@test "GraphQL source and platform changes rebuild, while failures preserve the last good SDL" {
  run mise -C "$FIXTURE_ROOT" run --raw merge-graphql-schemas
  [ "$status" -eq 0 ]
  printf '%s\n' 'type Query { previous: Boolean! }' > .generated/graphql/recipe-db.graphqls
  printf '%s\n' 'type Query { consumer: Boolean! }' > mcp/recipe-db.graphqls

  : > "$DOCKER_LOG"
  run env BUILD_STATUS=19 mise -C "$FIXTURE_ROOT" run --raw merge-graphql-schemas
  [ "$status" -ne 0 ]
  [ "$(cat "$DOCKER_LOG")" = "build" ]
  [ "$(cat .generated/graphql/recipe-db.graphqls)" = 'type Query { previous: Boolean! }' ]
  [ "$(cat mcp/recipe-db.graphqls)" = 'type Query { consumer: Boolean! }' ]

  : > "$DOCKER_LOG"
  run env SCHEMA_STATUS=23 mise -C "$FIXTURE_ROOT" run --raw merge-graphql-schemas
  [ "$status" -ne 0 ]
  [ "$(cat "$DOCKER_LOG")" = $'build\nprint' ]
  [ "$(cat .generated/graphql/recipe-db.graphqls)" = 'type Query { previous: Boolean! }' ]
  [ "$(cat mcp/recipe-db.graphqls)" = 'type Query { consumer: Boolean! }' ]

  : > "$DOCKER_LOG"
  run env DOCKER_DEFAULT_PLATFORM=linux/arm64 mise -C "$FIXTURE_ROOT" run --raw merge-graphql-schemas
  [ "$status" -eq 0 ]
  [ "$(cat "$DOCKER_LOG")" = $'build\nprint' ]
  [ "$(cat .generated/graphql/recipe-db.graphqls)" = "$SCHEMA_TEXT" ]

  : > "$DOCKER_LOG"
  printf '%s\n' '// source edit' >> graphql/src/main.rs
  touch -d @1000000000 graphql/src/main.rs
  run mise -C "$FIXTURE_ROOT" run --raw merge-graphql-schemas
  [ "$status" -eq 0 ]
  [ "$(cat "$DOCKER_LOG")" = $'build\nprint' ]
}
