#!/usr/bin/env bats

load test_helper

setup() {
  setup_fixture traefik-ingress-entrypoint.sh
  mkdir -p runtime secrets
  printf '%s\n' 'http: {}' > routes.yml
  printf '%s' 'abcdefghijklmnopqrstuvwxyz0123456789_-ABCDE' > secrets/token
  sed -i \
    -e "s|/run/secrets/graphql-ingress-secret|$FIXTURE_ROOT/secrets/token|g" \
    -e "s|/traefik_config.yml|$FIXTURE_ROOT/routes.yml|g" \
    -e "s|/run/traefik|$FIXTURE_ROOT/runtime|g" \
    -e "s|/entrypoint.sh|$FIXTURE_ROOT/entrypoint.sh|g" \
    .scripts/traefik-ingress-entrypoint.sh
  cat > entrypoint.sh << 'EOF'
#!/bin/sh
printf '%s\n' "$@" > arguments
test -z "${secret+x}"
exit 23
EOF
  chmod +x entrypoint.sh
}

teardown() {
  if [ -n "${proxy_container:-}" ]; then
    docker rm -f "$proxy_container" > /dev/null
  fi
  if [ -n "${mock_container:-}" ]; then
    docker rm -f "$mock_container" > /dev/null
  fi
  if [ -n "${network_id:-}" ]; then
    docker network rm "$network_id" > /dev/null
  fi
}

@test "ingress entrypoint renders a private runtime middleware without logging the token" {
  run sh .scripts/traefik-ingress-entrypoint.sh --api=true '--argument=two words'
  [ "$status" -eq 23 ]
  [ -z "$output" ]
  [ "$(cat arguments)" = $'--api=true\n--argument=two words' ]
  cmp routes.yml runtime/routes.yml
  [ "$(stat -c %a runtime/ingress.yml)" = 600 ]
  [ "$(stat -c %a runtime/routes.yml)" = 600 ]
  [ "$(yq '.http.middlewares.graphql-ingress.headers.customRequestHeaders.X-Internal-Ingress-Token' runtime/ingress.yml)" = "$(cat secrets/token)" ]
}

@test "ingress entrypoint accepts a trailing newline and refuses invalid secrets before startup" {
  printf '\n' >> secrets/token
  run sh .scripts/traefik-ingress-entrypoint.sh
  [ "$status" -eq 23 ]
  rm arguments runtime/ingress.yml runtime/routes.yml
  for value in '' short 'abcdefghijklmnopqrstuvwxyz0123456789_+ABCDE' 'abcdefghijklmnopqrstuvwxyz0123456789_-ABCDEF'; do
    printf '%s' "$value" > secrets/token
    run sh .scripts/traefik-ingress-entrypoint.sh
    [ "$status" -ne 0 ]
    [[ "$output" == *"GraphQL ingress secret must be 43 URL-safe base64 characters"* ]]
    [ ! -e arguments ]
    [ ! -e runtime/ingress.yml ]
  done
  rm secrets/token
  run sh .scripts/traefik-ingress-entrypoint.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"secrets/token"* ]]
  [ ! -e arguments ]
}

@test "real Traefik injects the token only after authentication and hides secret configuration" {
  [ "${TEST_AUTH_INGRESS:-false}" = true ] || skip "run mise run test-auth-ingress for Docker verification"
  mkdir -p .scripts/lib .scripts/templates graphql
  cp "$BATS_TEST_DIRNAME/../lib/project-metadata.sh" .scripts/lib/
  cp "$BATS_TEST_DIRNAME/../templates/traefik-template.yml" .scripts/templates/
  cp "$BATS_TEST_DIRNAME/../templates/service-template.lib.yml" .scripts/templates/
  cp "$BATS_TEST_DIRNAME/../templates/browse-maintenance-template.lib.yml" .scripts/templates/
  cp "$BATS_TEST_DIRNAME/../../graphql/.project.yaml" graphql/
  use_mise_tools
  . .scripts/lib/project-metadata.sh
  printf '%s\n' '{"repository":"github:example/fixture"}' > package.json
  project_metadata_to_jsonl "$PWD" projects.jsonl
  jq -n --slurpfile projects projects.jsonl '{projects:$projects}' > route-values.json
  run sh -c 'mise exec -- ytt \
    -f .scripts/templates/traefik-template.yml \
    -f .scripts/templates/service-template.lib.yml \
    -f .scripts/templates/browse-maintenance-template.lib.yml \
    --data-values-file route-values.json > traefik.yml'
  [ "$status" -eq 0 ]
  yq -i '
    .http.services.recipe-db-graphql.loadBalancer.servers[0].url = "http://mock:8000" |
    .http.services.oauth2-proxy.loadBalancer.servers[0].url = "http://mock:8000" |
    .http.middlewares.oauth2-forward-auth.forwardAuth.address = "http://mock:8000/oauth2/auth"
  ' traefik.yml
  cp "$BATS_TEST_DIRNAME/fixtures/ingress-server.py" server.py
  network_id=$(docker network create "recipe-db-ingress-test-$(basename "$BATS_TEST_TMPDIR")-$$")
  mock_container=$(docker run -d --network "$network_id" --network-alias mock \
    --mount "type=bind,src=$FIXTURE_ROOT,dst=/fixture,readonly" \
    python:3.13-slim python /fixture/server.py)
  proxy_container=$(docker run -d --network "$network_id" \
    -p 127.0.0.1::80 -p 127.0.0.1::3000 \
    --mount "type=bind,src=$FIXTURE_ROOT/traefik.yml,dst=/traefik_config.yml,readonly" \
    --mount "type=bind,src=$FIXTURE_ROOT/secrets/token,dst=/run/secrets/graphql-ingress-secret,readonly" \
    --mount "type=bind,src=$BATS_TEST_DIRNAME/../traefik-ingress-entrypoint.sh,dst=/ingress-entrypoint.sh,readonly" \
    --tmpfs /run/traefik:mode=0700 --entrypoint /bin/sh traefik:v3.7 \
    /ingress-entrypoint.sh --api=true --providers.file.directory=/run/traefik \
    --entrypoints.web.address=:80 --entrypoints.rest-internal.address=:3000 \
    --entrypoints.web.http.aliasHeadersStrategy=delete \
    --entrypoints.rest-internal.http.aliasHeadersStrategy=delete \
    --entrypoints.web.http.middlewares=identity-strip@file \
    --entrypoints.rest-internal.http.middlewares=identity-strip@file)
  web="http://$(docker port "$proxy_container" 80)"
  internal="http://$(docker port "$proxy_container" 3000)"
  for _ in {1..30}; do
    if curl -fsS "$web/graphql" -o response.json 2> /dev/null; then
      break
    fi
    sleep 1
  done
  jq -e '.ingress == true and .user == null and .authorization == null' response.json

  curl -fsS "$web/graphql" \
    -H 'X-Internal-Ingress-Token: forged' -H 'X-Internal-Ingress-Token: duplicate' \
    -H 'X_Internal_Ingress_Token: alias' -H 'X-Auth-Request-User: forged' \
    -H 'X_Auth_Request_User: alias' -o response.json
  jq -e '.ingress == true and .user == null' response.json
  curl -fsS "$web/graphql" -H 'Cookie: _oauth2_proxy=valid' \
    -H 'X-Internal-Ingress-Token: forged' -o response.json
  jq -e '.ingress == true and .user == "test-user"' response.json
  curl -fsS "$web/graphql" -H 'Cookie: _oauth2_proxy=invalid' \
    -H 'Authorization: Bearer test' -o response.json
  jq -e '.ingress == true and .user == null and .authorization == "Bearer test"' response.json
  [ "$(curl -sS -o response.json -w '%{http_code}' "$web/graphql" -H 'Cookie: _oauth2_proxy=invalid')" = 401 ]
  curl -fsS "$web/oauth2/start" -H 'X-Internal-Ingress-Token: forged' \
    -H 'X-Auth-Request-User: forged' -o response.json
  jq -e '.ingress == false and .user == null' response.json

  for path in routers services; do
    curl -fsS "$internal/api/http/$path" -o response.json
    run grep -qF "$(cat secrets/token)" response.json
    [ "$status" -eq 1 ]
  done
  for path in api/rawdata api/http/middlewares api/http/middlewares/graphql-ingress@file api/support-dump dashboard/ graphql; do
    [ "$(curl -sS -o response.json -w '%{http_code}' "$internal/$path")" = 404 ]
  done
  [ "$(curl -sS -o response.json -w '%{http_code}' "$web/api/http/services")" = 404 ]
  docker logs "$proxy_container" > proxy.log 2>&1
  run grep -qF "$(cat secrets/token)" proxy.log
  [ "$status" -eq 1 ]
}
