#!/usr/bin/env bats

load test_helper

setup() {
  setup_fixture generate-docker-compose.sh
  cp -R "$BATS_TEST_DIRNAME/../templates" .scripts/
  use_mise_tools
  unset CI
  printf '%s\n' '{"repository":"github:example/fixture"}' > package.json
  mkdir fixtures
  cat > fixtures/.project.yaml << 'EOF'
devcontainer:
  ports: [80]
traefik:
  labels:
    http:
      routers:
        fixtures:
          rule: "PathPrefix(`/fixture`)"
          entrypoints: rest-internal
      services:
        fixtures:
          loadBalancer:
            healthCheck:
              path: /
---
category: static
EOF

  for category in backend frontend job test; do
    mkdir -p "$category"
    cat > "$category/.project.yaml" << EOF
category: $category
devcontainer:
  ports: [8000]
traefik:
  labels:
    http:
      routers:
        $category:
          rule: "PathPrefix(\`/$category\`)"
          entrypoints: rest-internal
      services:
        $category:
          loadBalancer:
            server:
              port: 8000
---
test: echo tested
EOF
  done
}

assert_compose() {
  run yq -o=json '.' docker-compose.yml
  [ "$status" -eq 0 ]
  jq -e "$1" <<< "$output"
}

@test "development includes jobs and test runners and removes stale Traefik config" {
  printf '%s\n' stale > traefik.yml

  run sh .scripts/generate-docker-compose.sh

  [ "$status" -eq 0 ]
  [ ! -e traefik.yml ]
  assert_compose '
    (.services | keys) == ["backend", "fixtures", "frontend", "job", "test", "traefik"]
    and .services.traefik.ports == ["8080:80", "3000:3000"]
    and .services.job.profiles == ["development"]
    and .services.test.profiles == ["test"]
    and .services.test.command == ["/bin/sh", "-c", "echo tested"]
    and .services.test.volumes == ["./test/target:/app/target"]
    and (has("volumes") | not)
  '
}

@test "production excludes jobs and tests and generates persistent storage and routing" {
  run sh .scripts/generate-docker-compose.sh production

  [ "$status" -eq 0 ]
  assert_compose '
    (.services | keys) == ["backend", "frontend", "traefik"]
    and .services.traefik.ports == ["8080:80"]
    and .services.backend.environment.PRODUCTION == "true"
    and .services.backend.environment.DATA_LOCATION == "/app/data/backend"
    and .services.backend.volumes == ["data:/app/data"]
    and .volumes.data.name == "recipe-db-data"
    and .services.backend.build.labels["org.opencontainers.image.source"] == "https://github.com/example/fixture"
  '
  run yq -o=json '.' traefik.yml
  [ "$status" -eq 0 ]
  jq -e '
    .http.services.backend.loadBalancer.servers == [{"url":"http://backend:8000"}]
    and .http.routers.frontend.service == "frontend"
  ' <<< "$output"
}

@test "backend mode excludes frontends but retains development jobs and tests" {
  run sh .scripts/generate-docker-compose.sh backend

  [ "$status" -eq 0 ]
  assert_compose '(.services | keys) == ["backend", "fixtures", "job", "test", "traefik"]'
}

@test "prepare leaves existing configuration files untouched" {
  printf '%s\n' existing-compose > docker-compose.yml
  printf '%s\n' existing-traefik > traefik.yml

  run sh .scripts/generate-docker-compose.sh prepare

  [ "$status" -eq 0 ]
  [ "$output" = "docker-compose.yml already exists, skipping generation" ]
  [ "$(cat docker-compose.yml)" = existing-compose ]
  [ "$(cat traefik.yml)" = existing-traefik ]
}

@test "unknown arguments fail before creating configuration files" {
  run --separate-stderr sh .scripts/generate-docker-compose.sh invalid

  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$stderr" = "unknown argument: invalid" ]
  [ ! -e docker-compose.yml ]
  [ ! -e traefik.yml ]
}

@test "prepare generates missing configuration" {
  run sh .scripts/generate-docker-compose.sh prepare

  [ "$status" -eq 0 ]
  assert_compose '.services.backend.container_name == "backend"'
}

@test "CI enables production registry cache writes but not development cache writes" {
  export CI=true
  run sh .scripts/generate-docker-compose.sh prod

  [ "$status" -eq 0 ]
  assert_compose '
    .services.backend.build.cache_to == ["type=registry,mode=max,ref=ghcr.io/dhhyi/recipe-db-backend-cache"]
  '

  run sh .scripts/generate-docker-compose.sh

  [ "$status" -eq 0 ]
  assert_compose '(.services.backend.build | has("cache_to") | not)'
}

@test "fixtures use a dedicated read-only service" {
  run sh .scripts/generate-docker-compose.sh

  [ "$status" -eq 0 ]
  # The jq filter needs literal backticks for the router rule.
  # shellcheck disable=SC2016
  assert_compose '
    .services.fixtures.profiles == ["test"]
    and .services.fixtures.read_only == true
    and .services.fixtures.tmpfs == ["/var/cache/nginx", "/var/run"]
    and (.services.fixtures | has("command") | not)
    and (.services.fixtures | has("user") | not)
    and .services.fixtures.labels == ["traefik.enable=true", "traefik.http.routers.fixtures.rule=PathPrefix(`/fixture`)", "traefik.http.routers.fixtures.entrypoints=rest-internal", "traefik.http.services.fixtures.loadBalancer.healthCheck.path=/"]
  '
}
