#!/usr/bin/env bats

load test_helper

setup() {
  setup_fixture generate-docker-compose.sh
  cp -R "$BATS_TEST_DIRNAME/../templates" .scripts/
  use_mise_tools
  unset CI REGISTRY_CACHE_SUFFIX
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

setup_browse() {
  mv frontend browse
  cat > browse/.project.yaml << 'EOF'
devcontainer:
  ports: [3000]
  environment:
    NATS_URL: nats://nats:4222
traefik:
  labels:
    http:
      services:
        recipe-db-frontend:
          loadBalancer:
            healthCheck:
              interval: 10s
              timeout: 1s
              path: /health
      routers:
        frontend:
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
        graphql-anonymous:
          rule: "PathPrefix(`/graphql`)"
          entrypoints: web
          priority: 100
        graphql-cookie:
          rule: "PathPrefix(`/graphql`) && HeaderRegexp(`Cookie`, `(^|;\\s*)_oauth2_proxy(_[^=;\\s]*)?(=|;|\\s|$)`)"
          entrypoints: web
          priority: 200
          middlewares: oauth2-forward-auth
        graphql-bearer:
          rule: "PathPrefix(`/graphql`) && HeaderRegexp(`Authorization`, `.*`)"
          entrypoints: web
          priority: 300
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

@test "development includes jobs and test runners and removes stale Traefik config" {
  printf '%s\n' stale > traefik.yml

  run sh .scripts/generate-docker-compose.sh

  [ "$status" -eq 0 ]
  [ ! -e traefik.yml ]
  assert_compose '
    (.services | keys) == ["backend", "fixtures", "frontend", "job", "nats", "nats-init", "test", "traefik"]
    and .services.traefik.image == "traefik:v3.7"
    and .services.traefik.ports == ["8080:80", "3000:3000"]
    and .services.job.profiles == ["development"]
    and .services.test.profiles == ["test"]
    and .services.test.command == ["/bin/sh", "-c", "echo tested"]
    and .services.test.volumes == ["./test/target:/app/target"]
    and all(.services | to_entries[] | select(.value | has("build"));
      .value.build.cache_from == ["type=registry,ref=ghcr.io/dhhyi/recipe-db-" + .key + "-cache"]
      and (.value.build | has("cache_to") | not))
    and .volumes["nats-data"].name == "recipe-db-nats-data"
    and (.volumes | has("data") | not)
  '
}

@test "production excludes jobs and tests and generates persistent storage and routing" {
  run sh .scripts/generate-docker-compose.sh production

  [ "$status" -eq 0 ]
  assert_compose '
    (.services | keys) == ["backend", "frontend", "nats", "nats-init", "traefik"]
    and .services.traefik.image == "traefik:v3.7"
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
  assert_compose '(.services | keys) == ["backend", "fixtures", "job", "nats", "nats-init", "test", "traefik"]'
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
  run env CI=true sh .scripts/generate-docker-compose.sh prod

  [ "$status" -eq 0 ]
  assert_compose '
    .services.backend.build.cache_from == ["type=registry,ref=ghcr.io/dhhyi/recipe-db-backend-cache"]
    and .services.backend.build.cache_to == ["type=registry,mode=max,ref=ghcr.io/dhhyi/recipe-db-backend-cache"]
  '

  run env CI=true sh .scripts/generate-docker-compose.sh

  [ "$status" -eq 0 ]
  assert_compose '(.services.backend.build | has("cache_to") | not)'
}

@test "ARM64 cache namespace is reused in development and exported only in production CI" {
  run env CI=true REGISTRY_CACHE_SUFFIX=-arm64 sh .scripts/generate-docker-compose.sh

  [ "$status" -eq 0 ]
  assert_compose '
    all(.services | to_entries[] | select(.value | has("build"));
      .value.build.cache_from == ["type=registry,ref=ghcr.io/dhhyi/recipe-db-" + .key + "-cache-arm64"]
      and (.value.build | has("cache_to") | not))
  '

  run env CI=true REGISTRY_CACHE_SUFFIX=-arm64 sh .scripts/generate-docker-compose.sh prod

  [ "$status" -eq 0 ]
  assert_compose '
    all(.services | to_entries[] | select(.value | has("build"));
      .value.build.cache_from == ["type=registry,ref=ghcr.io/dhhyi/recipe-db-" + .key + "-cache-arm64"]
      and .value.build.cache_to == ["type=registry,mode=max,ref=ghcr.io/dhhyi/recipe-db-" + .key + "-cache-arm64"])
  '

  run env REGISTRY_CACHE_SUFFIX=-arm64 sh .scripts/generate-docker-compose.sh prod

  [ "$status" -eq 0 ]
  assert_compose 'all(.services[] | select(has("build")); (.build | has("cache_to") | not))'
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

@test "bus is private, bounded and persistent in every deployment mode" {
  for mode in "" production backend; do
    run sh .scripts/generate-docker-compose.sh $mode
    [ "$status" -eq 0 ]
    # shellcheck disable=SC2016
    assert_compose '
      .services.nats.image == "nats:2.11.10-alpine"
      and (.services.nats | has("ports") | not)
      and (.services.nats | has("labels") | not)
      and .services.nats.environment.VERBOSE == "${VERBOSE:-false}"
      and .services.nats.mem_limit == "128m"
      and .services.nats.volumes == ["./message-bus/nats.conf:/etc/nats/nats.conf:ro", "nats-data:/data"]
      and .services.nats.healthcheck.test[-1] == "http://127.0.0.1:8222/healthz?js-enabled-only=true"
      and .services["nats-init"].command == ["provision-events"]
      and .services["nats-init"].depends_on.nats.condition == "service_healthy"
      and .volumes["nats-data"].name == "recipe-db-nats-data"
    '
  done
}

@test "bus clients need only a URL and GraphQL waits for provisioning" {
  setup_graphql
  for mode in "" production backend; do
    run sh .scripts/generate-docker-compose.sh $mode
    [ "$status" -eq 0 ]
    assert_compose '
      .services.graphql.environment.NATS_URL == "nats://nats:4222"
      and .services.graphql.environment.AUTH_TRUSTED_ISSUER == "https://accounts.google.com"
      and .services.graphql.secrets == ["auth-accounts.json"]
      and .secrets["auth-accounts.json"].file == "./.secrets/auth-accounts.json"
      and (.services.graphql.environment | has("NATS_USER") | not)
      and (.services.graphql.environment | has("NATS_PASSWORD") | not)
      and .services["nats-init"].environment.NATS_URL == "nats://nats:4222"
      and (.services["nats-init"].environment | keys) == ["NATS_URL", "VERBOSE"]
      and (.services.nats.environment | keys) == ["VERBOSE"]
      and .services.graphql.depends_on["nats-init"].condition == "service_completed_successfully"
    '
  done
}

@test "OAuth2 Proxy routing, secrets, Redis, and identity isolation are generated" {
  setup_graphql
  run env GOOGLE_OAUTH_CLIENT_ID=test-client sh .scripts/generate-docker-compose.sh production

  [ "$status" -eq 0 ]
  # The jq expression checks literal Compose interpolation syntax.
  # shellcheck disable=SC2016
  assert_compose '
    .services["oauth2-proxy"].image == "quay.io/oauth2-proxy/oauth2-proxy:v7.15.5@sha256:8498b0d0ef0a7b29686414000a08aee467f02d0299c9ed1e006a8f33fc017916"
    and .services["oauth2-proxy"].networks == ["auth-ingress", "oauth2-sessions", "oauth2-egress"]
    and .services["oauth2-proxy"].secrets == ["google-oauth-client-secret", "oauth2-cookie-secret"]
    and .services["oauth2-proxy"].environment.OAUTH2_PROXY_COOKIE_SECURE == "true"
    and .services["oauth2-proxy"].environment.OAUTH2_PROXY_COOKIE_EXPIRE == "168h"
    and .services["oauth2-proxy"].environment.OAUTH2_PROXY_COOKIE_REFRESH == "50m"
    and .services["oauth2-proxy"].environment.OAUTH2_PROXY_REDIRECT_URL == "${GOOGLE_OAUTH_REDIRECT_URL:?Set GOOGLE_OAUTH_REDIRECT_URL to the exact callback URL}"
    and .services["oauth2-proxy"].environment.OAUTH2_PROXY_WHITELIST_DOMAINS == "${GOOGLE_OAUTH_REDIRECT_HOST:?Set GOOGLE_OAUTH_REDIRECT_HOST to the exact public host}"
    and .services.redis.image == "redis:8.10.2-alpine@sha256:0bf6577d7774e592b29d093e3ac9390eb91e13d72c21e506afce736de5e0eeb0"
    and .services.redis.networks == ["oauth2-sessions"]
    and (.services.redis | has("ports") | not)
    and .services.redis.volumes == ["oauth2-sessions-data:/data"]
    and .services.graphql.networks == ["auth-ingress"]
    and .services.graphql.environment.GRAPHQL_TRUSTED_INGRESS_IP == "10.231.65.2"
    and .services.traefik.networks["auth-ingress"].ipv4_address == "10.231.65.2"
    and .networks["auth-ingress"].internal == true
    and .networks["oauth2-sessions"].internal == true
    and (.networks["oauth2-egress"] | has("internal") | not)
    and .secrets["google-oauth-client-secret"].file == "${GOOGLE_OAUTH_CLIENT_SECRET_FILE:?Set GOOGLE_OAUTH_CLIENT_SECRET_FILE to the mounted OAuth client-secret file}"
    and .secrets["oauth2-cookie-secret"].file == "${OAUTH2_COOKIE_SECRET_FILE:?Set OAUTH2_COOKIE_SECRET_FILE to the mounted OAuth cookie-secret file}"
  '

  run yq -o=json '.' oauth2-proxy-alpha.yml
  [ "$status" -eq 0 ]
  jq -e '
    .providers[0].provider == "oidc"
    and .providers[0].clientID == "test-client"
    and .providers[0].scope == "openid email"
    and .providers[0].code_challenge_method == "S256"
    and .providers[0].additionalClaims == ["iss", "email_verified"]
    and .providers[0].oidcConfig.issuerURL == "https://accounts.google.com"
    and .providers[0].oidcConfig.emailClaim == "email"
    and .providers[0].oidcConfig.insecureAllowUnverifiedEmail == false
    and .providers[0].oidcConfig.insecureSkipNonce == false
    and (.providers[0].oidcConfig | has("userIDClaim") | not)
  ' <<< "$output"

  run yq -o=json '.' traefik.yml
  [ "$status" -eq 0 ]
  jq -e '
    .http.routers["graphql-anonymous"].priority == 100
    and .http.routers["graphql-cookie"].priority == 200
    and .http.routers["graphql-cookie"].middlewares == ["oauth2-forward-auth"]
    and .http.routers["graphql-bearer"].priority == 300
    and (.http.routers["graphql-bearer"] | has("middlewares") | not)
    and .http.routers["oauth2-public"].rule == "PathRegexp(`^/oauth2/(start|callback|sign_in|sign_out)$`)"
    and (.http.routers["oauth2-public"].rule | contains("/oauth2/auth") | not)
    and .http.middlewares["oauth2-forward-auth"].forwardAuth.trustForwardHeader == false
    and .http.middlewares["oauth2-forward-auth"].forwardAuth.authRequestHeaders == ["Cookie", "Authorization"]
    and .http.middlewares["oauth2-forward-auth"].forwardAuth.authResponseHeaders == ["X-Auth-Request-User", "X-Auth-Request-Issuer", "X-Auth-Request-Email", "X-Auth-Request-Email-Verified"]
    and .http.middlewares["oauth2-forward-auth"].forwardAuth.addAuthCookiesToResponse == ["_oauth2_proxy"]
    and .http.middlewares["identity-strip"].headers.customRequestHeaders["X-Auth-Request-User"] == ""
    and .http.services["oauth2-proxy"].loadBalancer.servers == [{"url": "http://oauth2-proxy:4180"}]
  ' <<< "$output"
  cookie_regex=$(jq -r '.http.routers["graphql-cookie"].rule | capture("HeaderRegexp\\(`Cookie`, `(?<pattern>[^`]*)`\\)") | .pattern' <<< "$output")
  run node -e '
    const matcher = new RegExp(process.argv[1]);
    const credentialCookies = ["_oauth2_proxy=stale", "_oauth2_proxy_0=chunk", "other=1; _oauth2_proxy_1=chunk", "_oauth2_proxy_bad=malformed", "_oauth2_proxy"];
    const unrelatedCookies = ["other=1", "_oauth2_proxyX=unrelated", "__oauth2_proxy=unrelated"];
    if (credentialCookies.some((cookie) => !matcher.test(cookie)) || unrelatedCookies.some((cookie) => matcher.test(cookie))) {
      process.exit(1);
    }
  ' "$cookie_regex"
  [ "$status" -eq 0 ]

  run env GOOGLE_OAUTH_CLIENT_ID=test-client sh .scripts/generate-docker-compose.sh
  [ "$status" -eq 0 ]
  # The jq expression checks literal Compose interpolation syntax.
  # shellcheck disable=SC2016
  assert_compose '
    (.services.traefik.command | index("--entrypoints.web.http.aliasHeadersStrategy=delete") != null)
    and (.services.traefik.command | index("--entrypoints.web.http.middlewares=identity-strip@docker") != null)
    and (.services.traefik.command | index("--entrypoints.rest-internal.http.middlewares=identity-strip@docker") != null)
    and (.services.graphql.labels | index("traefik.http.routers.graphql-bearer.rule=PathPrefix(`/graphql`) && HeaderRegexp(`Authorization`, `.*`)") != null)
    and (.services.graphql.labels | index("traefik.http.routers.graphql-cookie.rule=PathPrefix(`/graphql`) && HeaderRegexp(`Cookie`, `(^|;\\s*)_oauth2_proxy(_[^=;\\s]*)?(=|;|\\s|$)`)") != null)
    and (.services.graphql.labels | index("traefik.http.routers.graphql-cookie.middlewares=oauth2-forward-auth") != null)
    and (.services["oauth2-proxy"].labels | index("traefik.http.routers.oauth2-public.rule=PathRegexp(`^/oauth2/(start|callback|sign_in|sign_out)$`)") != null)
    and (.services["oauth2-proxy"].labels | index("traefik.docker.network=recipe-db-auth-ingress") != null)
    and .services["oauth2-proxy"].environment.OAUTH2_PROXY_COOKIE_SECURE == "${OAUTH2_COOKIE_SECURE:-false}"
    and .services.graphql.networks == ["auth-ingress"]
  '
}

@test "search uses GraphQL through Traefik's application entrypoint" {
  run yq eval-all -r 'select(documentIndex == 0).devcontainer.environment.GRAPHQL_URL' "$BATS_TEST_DIRNAME/../../search/.project.yaml"

  [ "$status" -eq 0 ]
  [ "$output" = "http://traefik/graphql" ]
}

@test "auth ingress network and trusted address can be overridden" {
  setup_graphql
  run env AUTH_INGRESS_SUBNET=192.168.240.0/24 GRAPHQL_TRUSTED_INGRESS_IP=192.168.240.9 sh .scripts/generate-docker-compose.sh production

  [ "$status" -eq 0 ]
  assert_compose '
    .services.graphql.environment.GRAPHQL_TRUSTED_INGRESS_IP == "192.168.240.9"
    and .services.traefik.networks["auth-ingress"].ipv4_address == "192.168.240.9"
    and .networks["auth-ingress"].ipam.config[0].subnet == "192.168.240.0/24"
  '
}

@test "browse waits for provisioning and retains its bus URL in development and production" {
  setup_browse
  for mode in "" production; do
    run sh .scripts/generate-docker-compose.sh $mode
    [ "$status" -eq 0 ]
    assert_compose '
      .services.browse.environment.NATS_URL == "nats://nats:4222"
      and .services.browse.depends_on["nats-init"].condition == "service_completed_successfully"
    '
  done
}

@test "browse maintenance is independent pinned read-only infrastructure whenever browse is included" {
  setup_browse
  for mode in "" production prepare; do
    rm -f docker-compose.yml
    run sh .scripts/generate-docker-compose.sh $mode
    [ "$status" -eq 0 ]
    assert_compose '
      .services["browse-maintenance"].image == "nginx:stable-alpine@sha256:0985e772fb9f729e6fa0980da05fca5d9c468e870eed43071545afa9d2e27d94"
      and .services["browse-maintenance"].networks == ["intranet"]
      and .services["browse-maintenance"].restart == "unless-stopped"
      and .services["browse-maintenance"].read_only == true
      and .services["browse-maintenance"].tmpfs == ["/var/cache/nginx", "/var/run"]
      and .services["browse-maintenance"].volumes == [
        "./browse-maintenance/nginx.conf:/etc/nginx/conf.d/default.conf:ro",
        "./browse-maintenance/unavailable.html:/usr/share/nginx/html/unavailable.html:ro"
      ]
      and (.services["browse-maintenance"] | has("ports") or has("build") or has("depends_on") or has("secrets") or has("profiles") | not)
    '
  done
}

@test "development keeps browse errors and browser-only fallback on maintenance infrastructure" {
  setup_browse
  run sh .scripts/generate-docker-compose.sh
  [ "$status" -eq 0 ]
  # shellcheck disable=SC2016
  assert_compose '
    (.services | keys) == ["backend", "browse", "browse-maintenance", "fixtures", "job", "nats", "nats-init", "test", "traefik"]
    and (.services.browse.labels | index("traefik.http.routers.frontend.middlewares=frontend-compress,browse-unavailable") != null)
    and (.services.browse.labels | index("traefik.http.routers.frontend.priority=2") != null)
    and (.services.browse.labels | index("traefik.http.routers.frontend.rule=PathPrefix(`/`)") != null)
    and (.services.browse.labels | index("traefik.http.middlewares.frontend-compress.compress=True") != null)
    and (.services.browse.labels | index("traefik.http.services.recipe-db-frontend.loadBalancer.healthCheck.interval=10s") != null)
    and (.services.browse.labels | index("traefik.http.services.recipe-db-frontend.loadBalancer.healthCheck.timeout=1s") != null)
    and (.services.browse.labels | index("traefik.http.services.recipe-db-frontend.loadBalancer.healthCheck.path=/health") != null)
    and .services["browse-maintenance"].labels == [
      "traefik.enable=true",
      "traefik.http.routers.browse-maintenance.rule=PathPrefix(`/`) && !PathPrefix(`/graphql`) && !PathPrefix(`/mcp`) && !PathPrefix(`/public`) && !PathPrefix(`/images`) && !PathPrefix(`/edit`) && !PathPrefix(`/design`) && (Method(`GET`) || Method(`HEAD`)) && HeaderRegexp(`Accept`, `(?i)text/html`)",
      "traefik.http.routers.browse-maintenance.entrypoints=web",
      "traefik.http.routers.browse-maintenance.priority=1",
      "traefik.http.routers.browse-maintenance.service=browse-maintenance",
      "traefik.http.middlewares.browse-unavailable.errors.status=502-504",
      "traefik.http.middlewares.browse-unavailable.errors.statusRewrites.502-504=503",
      "traefik.http.middlewares.browse-unavailable.errors.service=browse-maintenance",
      "traefik.http.middlewares.browse-unavailable.errors.query=/unavailable.html",
      "traefik.http.services.browse-maintenance.loadBalancer.server.port=80"
    ]
    and (.services.backend.labels | all(.[]; contains("browse-unavailable") | not))
    and (.services.traefik.command | all(.[]; test("allowEmptyServices|allowNonRunning|middlewares") | not))
  '
}

@test "production preserves compression and cross-service errors with explicit fallback priority" {
  setup_browse
  run sh .scripts/generate-docker-compose.sh production
  [ "$status" -eq 0 ]
  assert_compose '
    (.services | keys) == ["backend", "browse", "browse-maintenance", "nats", "nats-init", "traefik"]
    and (.services["browse-maintenance"] | has("labels") | not)
  '
  run yq -o=json '.' traefik.yml
  [ "$status" -eq 0 ]
  # shellcheck disable=SC2016
  jq -e '
    .http.routers.frontend == {
      "service": "recipe-db-frontend", "rule": "PathPrefix(`/`)", "entrypoints": ["web"],
      "middlewares": ["frontend-compress", "browse-unavailable"], "priority": 2
    }
    and .http.routers["browse-maintenance"] == {
      "service": "browse-maintenance", "entrypoints": ["web"], "priority": 1,
      "rule": "PathPrefix(`/`) && !PathPrefix(`/graphql`) && !PathPrefix(`/mcp`) && !PathPrefix(`/public`) && !PathPrefix(`/images`) && !PathPrefix(`/edit`) && !PathPrefix(`/design`) && (Method(`GET`) || Method(`HEAD`)) && HeaderRegexp(`Accept`, `(?i)text/html`)"
    }
    and .http.routers.frontend.priority > .http.routers["browse-maintenance"].priority
    and .http.middlewares["browse-unavailable"].errors == {
      "status": ["502-504"], "statusRewrites": {"502-504": 503},
      "service": "browse-maintenance", "query": "/unavailable.html"
    }
    and .http.services["browse-maintenance"].loadBalancer.servers == [{"url": "http://browse-maintenance:80"}]
    and .http.services["recipe-db-frontend"].loadBalancer.healthCheck == {"interval": "10s", "timeout": "1s", "path": "/health"}
    and .http.middlewares["frontend-compress"].compress == true
    and .http.routers.backend.entrypoints == ["rest-internal"]
    and .http.routers.backend.service == "backend"
    and (.http.routers.backend | has("middlewares") | not)
    and (tostring | contains("@docker") | not)
  ' <<< "$output"
}

@test "backend combinations omit browse maintenance and all dangling frontend routing" {
  setup_browse
  for mode in backend "production backend" "backend prod" "backend prepare"; do
    rm -f docker-compose.yml
    read -r -a mode_args <<< "$mode"
    run sh .scripts/generate-docker-compose.sh "${mode_args[@]}"
    [ "$status" -eq 0 ]
    assert_compose '
      (.services | has("browse") or has("browse-maintenance") | not)
      and (tostring | contains("browse-unavailable") | not)
    '
    if [ -e traefik.yml ]; then
      run yq -o=json '.' traefik.yml
      [ "$status" -eq 0 ]
      jq -e '
        (.http.routers | keys) == ["backend", "traefik"]
        and (.http.services | keys) == ["backend"]
        and .http.middlewares == {}
        and (tostring | contains("browse") | not)
      ' <<< "$output"
    fi
  done
}

@test "search uses private persistent Typesense and file-backed API-key secrets" {
  mkdir search
  cat > search/.project.yaml << 'EOF'
devcontainer:
  ports: [3000]
  environment:
    NATS_URL: nats://nats:4222
    TYPESENSE_API_KEY_FILE: /run/secrets/typesense-api-key
traefik:
  labels:
    http:
      services:
        search:
          loadBalancer:
            healthCheck:
              path: /health
      routers:
        search:
          rule: "PathPrefix(`/search`)"
          entrypoints: rest-internal
---
category: api
EOF
  for mode in "" production backend; do
    run sh .scripts/generate-docker-compose.sh $mode
    [ "$status" -eq 0 ]
    assert_compose '
      .services.typesense.image | startswith("typesense/typesense:29.0@sha256:")
    '
    # shellcheck disable=SC2016
    assert_compose '
      (.services.typesense | has("ports") | not)
      and (.services.typesense | has("labels") | not)
      and (.services.typesense.environment | has("TYPESENSE_API_KEY") | not)
      and .services.typesense.secrets == ["typesense-api-key"]
      and .services.typesense.volumes == ["typesense-data:/data"]
      and .services.search.secrets == ["typesense-api-key"]
      and .services.search.volumes == ["search-data:/data"]
      and .services.search.environment.STATE_DIRECTORY == "/data"
      and .services.search.environment.TYPESENSE_API_KEY_FILE == "/run/secrets/typesense-api-key"
      and .services.search.depends_on["nats-init"].condition == "service_completed_successfully"
      and .services.search.depends_on.typesense.condition == "service_started"
      and .volumes["typesense-data"].name == "recipe-db-typesense-data"
      and .volumes["search-data"].name == "recipe-db-search-data"
      and (.secrets["typesense-api-key"].file | startswith("${TYPESENSE_API_KEY_FILE:"))
    '
    if [ "$mode" = production ]; then
      # shellcheck disable=SC2016
      assert_compose '.secrets["typesense-api-key"].file == "${TYPESENSE_API_KEY_FILE:?Set TYPESENSE_API_KEY_FILE to a private Typesense API key file}"'
    else
      # shellcheck disable=SC2016
      assert_compose '.secrets["typesense-api-key"].file == "${TYPESENSE_API_KEY_FILE:-./.secrets/typesense-api-key}"'
    fi
  done
}
