#!/usr/bin/env bats

load test_helper

compose() {
  docker compose -p "$lifecycle_project" -f compose.yaml "$@"
}

phase() {
  run compose run --rm -T runner "$1"
  if [ "$status" -ne 0 ]; then
    printf '%s\n' "$output"
    return 1
  fi
  printf '%s\n' "$output" | sed 's/^/# /' >&3
}

teardown() {
  if [ -n "${lifecycle_project:-}" ]; then
    if [ -z "${BATS_TEST_COMPLETED:-}" ]; then
      compose logs --no-color graphql browse oauth2-proxy traefik
    fi
    compose --profile runner down --volumes --remove-orphans
  fi
}

@test "real GraphQL and browse integrate OIDC lifecycle and auth dependency outages" {
  [ "${TEST_AUTH_LIFECYCLE:-false}" = true ] || skip "set TEST_AUTH_LIFECYCLE=true after mise run dev-up"
  setup_fixture traefik-ingress-entrypoint.sh
  lifecycle_project="recipe-db-auth-lifecycle-$$-$BATS_TEST_NUMBER"
  mkdir -p .scripts/lib .scripts/templates graphql browse secrets
  chmod 700 "$FIXTURE_ROOT" secrets
  cp "$BATS_TEST_DIRNAME/fixtures/auth-lifecycle/"* .
  cp "$BATS_TEST_DIRNAME/../lib/project-metadata.sh" .scripts/lib/
  cp "$BATS_TEST_DIRNAME/../templates/traefik-template.yml" .scripts/templates/
  cp "$BATS_TEST_DIRNAME/../templates/service-template.lib.yml" .scripts/templates/
  cp "$BATS_TEST_DIRNAME/../templates/browse-maintenance-template.lib.yml" .scripts/templates/
  cp "$BATS_TEST_DIRNAME/../templates/oauth2-proxy-alpha-template.yml" .scripts/templates/
  cp "$BATS_TEST_DIRNAME/../../graphql/.project.yaml" graphql/
  cp "$BATS_TEST_DIRNAME/../../browse/.project.yaml" browse/
  export AUTH_LIFECYCLE_GRAPHQL_IMAGE AUTH_LIFECYCLE_BROWSE_IMAGE
  AUTH_LIFECYCLE_GRAPHQL_IMAGE=$(docker image inspect ghcr.io/dhhyi/recipe-db-graphql:latest --format '{{.Id}}')
  AUTH_LIFECYCLE_BROWSE_IMAGE=$(docker image inspect ghcr.io/dhhyi/recipe-db-browse:latest --format '{{.Id}}')
  [ -n "$AUTH_LIFECYCLE_GRAPHQL_IMAGE" ] && [ -n "$AUTH_LIFECYCLE_BROWSE_IMAGE" ]
  printf '# GraphQL image %s; browse image %s\n' "$AUTH_LIFECYCLE_GRAPHQL_IMAGE" "$AUTH_LIFECYCLE_BROWSE_IMAGE" >&3
  openssl rand -base64 32 | tr -d '\n=' | tr '+/' '-_' > secrets/cookie
  openssl rand -hex 32 | tr -d '\n' > secrets/client
  openssl rand -hex 32 > secrets/bearer
  openssl rand -base64 32 | tr -d '\n=' | tr '+/' '-_' > secrets/ingress
  jq -n --rawfile secret secrets/bearer '{
    anonymous:{role:"anonymous"},tokens:[{id:"lifecycle-owner",secret:($secret|rtrimstr("\n")),role:"owner"}],
    googleAccounts:{"owner@example.test":"owner","member@example.test":"member"}
  }' > secrets/accounts.json
  chmod 444 secrets/*
  use_mise_tools
  . .scripts/lib/project-metadata.sh
  printf '%s\n' '{"repository":"github:example/fixture"}' > package.json
  project_metadata_to_jsonl "$PWD" projects.jsonl
  jq -n --slurpfile projects projects.jsonl '{projects:$projects,googleOAuthClientId:"recipe-db-auth-lifecycle"}' > values.json
  mise exec -- ytt \
    -f .scripts/templates/traefik-template.yml \
    -f .scripts/templates/service-template.lib.yml \
    -f .scripts/templates/browse-maintenance-template.lib.yml \
    --data-values-file values.json > routes.yml
  # shellcheck disable=SC2016
  yq -i '
    .http.routers.lifecycle-idp = {"rule":"Host(`idp.poc.test`)","priority":10000,"entryPoints":["web"],"service":"lifecycle-idp"} |
    .http.services.lifecycle-idp = {"loadBalancer":{"servers":[{"url":"http://issuer:8080"}]}}
  ' routes.yml
  mise exec -- ytt -f .scripts/templates/oauth2-proxy-alpha-template.yml \
    --data-values-file values.json > alpha.yaml
  yq -i '
    .providers[0].provider = "oidc" |
    .providers[0].oidcConfig.issuerURL = "http://idp.poc.test" |
    .providers[0].oidcConfig.skipDiscovery = false |
    del(.providers[0].oidcConfig.jwksURL, .providers[0].loginURL, .providers[0].redeemURL)
  ' alpha.yaml
  compose up -d --wait --wait-timeout 90
  phase basic
  phase lifecycle
  for dependency in redis oauth2-proxy; do
    phase prepare
    compose stop "$dependency"
    phase outage
    compose up -d --wait --wait-timeout 60 "$dependency"
    phase recovered
  done
  phase prepare
  compose exec -T redis redis-cli FLUSHALL
  phase lost
  started=$SECONDS
  compose stop -t 5 issuer
  [ "$((SECONDS - started))" -lt 5 ]
  [ "$(docker inspect "$(compose ps -a -q issuer)" --format '{{.State.ExitCode}}')" -eq 0 ]
}
