#!/usr/bin/env bats

load test_helper

setup() {
  setup_fixture generate-docker-compose.sh
  mkdir -p .scripts/lib
  cp "$BATS_TEST_DIRNAME/../lib/project-metadata.sh" .scripts/lib/
  cp "$BATS_TEST_DIRNAME/../refresh-render-inputs.sh" .scripts/
  cp -R "$BATS_TEST_DIRNAME/../templates" .scripts/
  use_mise_tools
  unset CI REGISTRY_CACHE_SUFFIX GOOGLE_OAUTH_CLIENT_ID \
    GOOGLE_OAUTH_CLIENT_SECRET_FILE OAUTH2_COOKIE_SECRET_FILE GRAPHQL_INGRESS_SECRET_FILE
  setup_mock_bin
  cat > bin/docker << 'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$MOCK_LOG"
case "$*" in
  "network inspect intranet") exit "${NETWORK_INSPECT_STATUS:-0}" ;;
  "network create intranet") exit "${NETWORK_CREATE_STATUS:-0}" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x bin/docker
  printf '%s\n' '{"repository":"github:example/fixture"}' > package.json

  mkdir fixtures
  cat > fixtures/.project.yaml << 'EOF'
devcontainer:
  ports: [80]
traefik: {}
---
category: static
EOF

  for category in backend job test; do
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
  setup_browse
  setup_graphql
  setup_search
  setup_tags
}

setup_browse() {
  mkdir browse
  cat > browse/.project.yaml << 'EOF'
devcontainer:
  ports: [3000]
  environment:
    NATS_URL: nats://nats:4222
traefik:
  labels:
    http:
      services:
        recipe-db-browse:
          loadBalancer:
            healthCheck:
              interval: 10s
              timeout: 1s
              path: /health
      routers:
        browse:
          rule: "PathPrefix(`/`)"
          entrypoints: web
          priority: 2
          middlewares: frontend-compress,browse-unavailable
      middlewares:
        frontend-compress:
          compress: true
---
category: frontend
EOF
}

setup_graphql() {
  mkdir graphql
  cat > graphql/.project.yaml << 'EOF'
devcontainer:
  ports: [4000]
traefik:
  labels:
    http:
      services:
        graphql:
          loadBalancer:
            healthCheck:
              path: /health
      routers:
        graphql:
          rule: "PathPrefix(`/graphql`)"
          entrypoints: web
          priority: 100
          service: graphql
        graphql-cookie:
          rule: "PathPrefix(`/graphql`) && HeaderRegexp(`Cookie`, `(^|;\\s*)_oauth2_proxy(_[^=;\\s]*)?(=|;|\\s|$)`)"
          entrypoints: web
          priority: 200
          service: graphql
          middlewares: oauth2-forward-auth
        graphql-bearer:
          rule: "PathPrefix(`/graphql`) && HeaderRegexp(`Authorization`, `.*`)"
          entrypoints: web
          priority: 300
          service: graphql
      middlewares:
        oauth2-forward-auth:
          forwardAuth:
            address: http://oauth2-proxy:4180/oauth2/auth
            trustForwardHeader: false
            authRequestHeaders: [Cookie, Authorization]
            authResponseHeaders:
              - X-Auth-Request-User
              - X-Auth-Request-Issuer
              - X-Auth-Request-Email
              - X-Auth-Request-Email-Verified
            addAuthCookiesToResponse: [_oauth2_proxy]
---
category: api
EOF
}

setup_search() {
  mkdir search
  cat > search/.project.yaml << 'EOF'
devcontainer:
  ports: [8100]
  environment:
    GRAPHQL_URL: http://traefik/graphql
traefik:
  labels:
    http:
      routers:
        search:
          rule: "PathPrefix(`/search`)"
          entrypoints: rest-internal
      services:
        search:
          loadBalancer:
            server:
              port: 8100
---
category: backend
EOF
}

setup_tags() {
  mkdir tags tags-test
  cat > tags/.project.yaml << 'EOF'
devcontainer:
  ports: [8900]
  environment:
    MODE: testing
    DATA_LOCATION: /data
traefik:
  labels:
    http:
      services:
        recipe-db-tags:
          loadBalancer:
            healthCheck:
              path: /health
      routers:
        tags:
          rule: "PathPrefix(`/tags`)"
          entrypoints: rest-internal
---
category: backend
EOF
  cat > tags-test/.project.yaml << 'EOF'
devcontainer:
  ports: [8901]
traefik: {}
---
category: test
test: echo tested
EOF
}

assert_compose() {
  run yq -o=json '.' docker-compose.yml
  [ "$status" -eq 0 ]
  jq -e --arg expected_uid "${2:-}" "$1" <<< "$output"
}

@test "no-argument generation renders the development stack and leaves production routing untouched" {
  printf '%s\n' existing-routes > traefik.yml

  run sh .scripts/generate-docker-compose.sh

  [ "$status" -eq 0 ]
  [ "$(cat traefik.yml)" = existing-routes ]
  # jq variables in the expression must remain literal for jq.
  # shellcheck disable=SC2016
  assert_compose '
    . as $root |
    all(["backend","browse","browse-maintenance","fixtures","graphql","job","nats","nats-init","oauth2-proxy","redis","search","tags","tags-production-test-api","tags-test","tags-test-api","test","traefik","typesense"][];
      . as $service | $root.services | has($service))
    and .services.traefik.ports == ["8080:80", "3000:3000"]
    and .services.job.profiles == ["development"]
    and .services.test.profiles == ["test"]
    and .services.test.command == ["/bin/sh", "-c", "echo tested"]
    and .services.test.volumes == ["./test/target:/app/target"]
    and all(.services | to_entries[] | select(.value | has("build"));
      (.key | if . == "tags-test-api" or . == "tags-production-test-api" then "tags" else . end) as $project
      | .value.build.cache_from == ["type=registry,ref=ghcr.io/dhhyi/recipe-db-" + $project + "-cache"]
      and (.value.build | has("cache_to") | not))
    and .volumes["nats-data"].name == "recipe-db-nats-data"
    and .volumes["oauth2-sessions-data"].name == "recipe-db-oauth2-sessions-data"
    and .volumes["tags-data"].name == "recipe-db-tags-data"
    and .services.tags.environment.MODE == "testing"
    and (.services.tags.environment | has("PRODUCTION") | not)
    and .services.tags.volumes == ["tags-data:/data"]
    and any(.services.tags.labels[]; . == "traefik.http.routers.tags.entrypoints=rest-internal")
    and .services["tags-test-api"].profiles == ["test"]
    and .services["tags-test-api"].environment.MODE == "testing"
    and (.services["tags-test-api"].environment | has("PRODUCTION") | not)
    and .services["tags-test-api"].tmpfs == ["/data"]
    and .services["tags-production-test-api"].environment.MODE == "production"
    and (.services["tags-production-test-api"].environment | has("PRODUCTION") | not)
    and .services["tags-production-test-api"].tmpfs == ["/data"]
    and (.volumes | has("data") | not)
  '
  [ -s oauth2-proxy-alpha.yml ]
  [ ! -e .secrets ]
  [ ! -s "$MOCK_LOG" ]
}

@test "removed modes fail before generated outputs or input state change" {
  run sh .scripts/generate-docker-compose.sh
  [ "$status" -eq 0 ]
  cp docker-compose.yml original-compose
  cp oauth2-proxy-alpha.yml original-oauth
  cp .generated/compose-inputs.json original-inputs

  for mode in prepare backend prod production "production backend"; do
    read -r -a arguments <<< "$mode"
    run --separate-stderr sh .scripts/generate-docker-compose.sh "${arguments[@]}"
    [ "$status" -eq 2 ]
    [ "$stderr" = "usage: generate-docker-compose.sh" ]
    cmp original-compose docker-compose.yml
    cmp original-oauth oauth2-proxy-alpha.yml
    cmp original-inputs .generated/compose-inputs.json
  done
}

@test "registry caches are read-only even under CI and ARM64 suffix remains supported" {
  run env CI=true REGISTRY_CACHE_SUFFIX=-arm64 sh .scripts/generate-docker-compose.sh

  [ "$status" -eq 0 ]
  # shellcheck disable=SC2016
  assert_compose '
    all(.services | to_entries[] | select(.value | has("build"));
      (.key | if . == "tags-test-api" or . == "tags-production-test-api" then "tags" else . end) as $project
      | .value.build.cache_from == ["type=registry,ref=ghcr.io/dhhyi/recipe-db-" + $project + "-cache-arm64"]
      and (.value.build | has("cache_to") | not))
  '
}

@test "OAuth2 routing and GraphQL identity boundaries remain in the development stack" {
  run env GOOGLE_OAUTH_CLIENT_ID=test-client sh .scripts/generate-docker-compose.sh

  [ "$status" -eq 0 ]
  # jq variables in the expression must remain literal for jq.
  # shellcheck disable=SC2016
  assert_compose '
    .services.graphql.networks == ["auth-ingress"]
    and .services.graphql.secrets == ["auth-accounts.json"]
    and .services.graphql.environment.NATS_URL == "nats://nats:4222"
    and .services["oauth2-proxy"].user == $expected_uid
    and .services["oauth2-proxy"].environment.OAUTH2_PROXY_COOKIE_SECURE == "${OAUTH2_COOKIE_SECURE:-false}"
    and .services["oauth2-proxy"].environment.OAUTH2_PROXY_REDIRECT_URL == "${GOOGLE_OAUTH_REDIRECT_URL:-http://localhost:8080/oauth2/callback}"
    and .services["oauth2-proxy"].secrets == ["google-oauth-client-secret", "oauth2-cookie-secret"]
    and .services.redis.networks == ["oauth2-sessions"]
    and .services.traefik.networks["auth-ingress"] == {}
    and .networks["auth-ingress"].internal == true
    and .networks["oauth2-sessions"].internal == true
    and (.networks["oauth2-egress"] | has("internal") | not)
    and (.services.traefik.command | index("--entrypoints.web.http.middlewares=identity-strip@docker") != null)
    and (.services.traefik.labels | index("traefik.http.middlewares.identity-strip.headers.customrequestheaders.X-Internal-Ingress-Token=") != null)
    and (.services.graphql.labels | index("traefik.http.routers.graphql-cookie.priority=200") != null)
    and (.services.graphql.labels | index("traefik.http.routers.graphql-bearer.priority=300") != null)
    and (.secrets["google-oauth-client-secret"].file | contains("./.secrets/google-oauth-client-secret"))
  ' "$(id -u):$(id -g)"
  run yq -o=json '.' oauth2-proxy-alpha.yml
  [ "$status" -eq 0 ]
  jq -e '
    .providers[0].clientID == "test-client"
    and .providers[0].oidcConfig.skipDiscovery == true
    and .providers[0].loginURL == "https://accounts.google.com/o/oauth2/v2/auth"
  ' <<< "$output"
}

@test "search persistence, dependency ordering, and private Typesense configuration remain" {
  run sh .scripts/generate-docker-compose.sh

  [ "$status" -eq 0 ]
  assert_compose '
    .services.search.volumes == ["search-data:/data"]
    and .services.search.environment.STATE_DIRECTORY == "/data"
    and .services.search.depends_on["nats-init"].condition == "service_completed_successfully"
    and .services.search.depends_on.typesense.condition == "service_started"
    and .services.typesense.volumes == ["typesense-data:/data"]
    and .services.typesense.secrets == ["typesense-api-key"]
    and (.services.typesense | has("ports") | not)
    and .services["nats-init"].depends_on.nats.condition == "service_healthy"
    and .services.graphql.depends_on["nats-init"].condition == "service_completed_successfully"
  '
}

@test "rendered services preserve build inputs, labels, and browser maintenance behavior" {
  awk '
    /^devcontainer:$/ {
      print
      print "  build:"
      print "    args:"
      print "      VERSION: 7"
      next
    }
    /^category: backend$/ {
      print
      print "dockerContext: ."
      next
    }
    { print }
  ' backend/.project.yaml > backend/.project.yaml.tmp
  mv backend/.project.yaml.tmp backend/.project.yaml

  run sh .scripts/generate-docker-compose.sh
  [ "$status" -eq 0 ]
  assert_compose '
    .services.backend.build.context == "."
    and .services.backend.build.dockerfile == "backend/Dockerfile"
    and .services.backend.build.args.VERSION == "7"
    and .services.browse.depends_on["nats-init"].condition == "service_completed_successfully"
    and .services["browse-maintenance"].read_only == true
    and (.services["browse-maintenance"].labels | any(contains("browse-maintenance")))
  '
}

@test "production route template retains production authentication and administrative protections" {
  . .scripts/lib/project-metadata.sh
  project_metadata_to_jsonl "$PWD" projects.jsonl
  jq -n --slurpfile projects projects.jsonl '{projects:$projects}' > route-values.json

  run mise exec -- ytt \
    -f .scripts/templates/traefik-template.yml \
    -f .scripts/templates/browse-maintenance-template.lib.yml \
    -f .scripts/templates/service-template.lib.yml \
    --data-values-file route-values.json -o json

  [ "$status" -eq 0 ]
  # jq variables in the expression must remain literal for jq.
  # shellcheck disable=SC2016
  jq -e '
    .http.routers["browse-maintenance"].rule as $maintenance_rule |
    .http.routers.browse.rule == "PathPrefix(`/`)"
    and .http.routers.browse.service == "recipe-db-browse"
    and .http.routers.browse.middlewares == ["frontend-compress", "browse-unavailable"]
    and .http.routers.browse.priority > .http.routers["browse-maintenance"].priority
    and .http.middlewares["frontend-compress"].compress == true
    and .http.routers["browse-maintenance"].entrypoints == ["web"]
    and .http.routers["browse-maintenance"].priority == 1
    and .http.routers["browse-maintenance"].service == "browse-maintenance"
    and ($maintenance_rule | contains("PathPrefix(`/`)"))
    and ($maintenance_rule | contains("Method(`GET`) || Method(`HEAD`)"))
    and ($maintenance_rule | contains("HeaderRegexp(`Accept`, `(?i)text/html`)"))
    and all(["/graphql", "/mcp", "/public", "/images", "/edit", "/design"][];
      . as $excluded_path | $maintenance_rule | contains("!PathPrefix(`" + $excluded_path + "`)"))
    and .http.middlewares["browse-unavailable"].errors.status == ["502-504"]
    and .http.middlewares["browse-unavailable"].errors.statusRewrites == {"502-504": 503}
    and .http.middlewares["browse-unavailable"].errors.service == "browse-maintenance"
    and .http.middlewares["browse-unavailable"].errors.query == "/unavailable.html"
    and .http.services["browse-maintenance"].loadBalancer.servers == [{"url": "http://browse-maintenance:80"}]
    and .http.services["recipe-db-browse"].loadBalancer.healthCheck == {"interval": "10s", "timeout": "1s", "path": "/health"}
    and .http.routers.backend.entrypoints == ["rest-internal"]
    and .http.routers.backend.service == "backend"
    and (.http.routers.backend | has("middlewares") | not)
    and .http.routers.graphql.priority == 100
    and .http.routers.graphql.middlewares == ["graphql-ingress"]
    and .http.routers["graphql-cookie"].priority == 200
    and .http.routers["graphql-cookie"].middlewares == ["oauth2-forward-auth", "graphql-ingress"]
    and .http.routers["graphql-bearer"].priority == 300
    and .http.routers.traefik.rule == "Method(`GET`) && (Path(`/api/http/routers`) || Path(`/api/http/services`))"
    and .http.routers["oauth2-public"].rule == "PathRegexp(`^/oauth2/(start|callback|sign_in|sign_out)$`)"
    and .http.middlewares["oauth2-forward-auth"].forwardAuth.trustForwardHeader == false
    and .http.middlewares["identity-strip"].headers.customRequestHeaders["X-Internal-Ingress-Token"] == ""
    and (.http.middlewares | has("graphql-ingress") | not)
    and (tostring | contains("@docker") | not)
  ' <<< "$output"
}

@test "a failure in the second ytt render preserves both last-good outputs" {
  run sh .scripts/generate-docker-compose.sh
  [ "$status" -eq 0 ]
  cp docker-compose.yml original-compose
  cp oauth2-proxy-alpha.yml original-oauth
  printf '%s\n' '#@ invalid ytt' >> .scripts/templates/oauth2-proxy-alpha-template.yml

  run sh .scripts/generate-docker-compose.sh

  [ "$status" -ne 0 ]
  cmp original-compose docker-compose.yml
  cmp original-oauth oauth2-proxy-alpha.yml
}
