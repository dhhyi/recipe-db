#!/bin/sh
# Runs the OAuth2 Proxy optional-authentication PoC matrix (#64) in an isolated
# Compose project and always removes the project and its ephemeral secrets.
set -eu

poc_root=$(cd "$(dirname "$0")" && pwd -P)
cd "$poc_root"
COMPOSE_PROJECT_NAME=recipe-db-auth-poc
export COMPOSE_PROJECT_NAME
secrets=
project_created=false

compose() {
  docker compose "$@"
}

cleanup() {
  status=$?
  trap - 0
  if [ "$project_created" = true ]; then
    compose logs --no-color --timestamps > "${AUTH_POC_LOG:-/tmp/auth-poc-compose.log}" 2>&1 || status=1
    compose --profile runner down --volumes --remove-orphans >&2 || status=1
  fi
  if [ -n "$secrets" ]; then
    rm -rf "$secrets"
  fi
  exit "$status"
}
trap cleanup 0
trap 'exit 130' 2
trap 'exit 143' 15

if [ -n "$(docker compose ls --all --quiet --filter "name=^${COMPOSE_PROJECT_NAME}\$")" ]; then
  echo "Refusing to reuse existing Compose project: $COMPOSE_PROJECT_NAME" >&2
  exit 1
fi

secrets=$(mktemp -d)
AUTH_POC_SECRETS=$secrets
export AUTH_POC_SECRETS
head -c 24 /dev/urandom | base64 | tr -d '\n' | tr '+/' '-_' > "$secrets/cookie-secret"
head -c 24 /dev/urandom | base64 | tr -d '\n' | tr '+/' '-_' > "$secrets/oidc-client-secret"
write_accounts() {
  printf '%s\n' "$1" > "$secrets/auth-accounts.json"
}
write_accounts '{"owner@example.test":"owner","member@example.test":"member","backup-owner@example.test":"owner"}'
chmod 755 "$secrets"
chmod 644 "$secrets"/*

project_created=true
compose up --detach --wait --quiet-pull

TARGET_PRIVATE_IP=$(docker inspect --format \
  "{{(index .NetworkSettings.Networks \"${COMPOSE_PROJECT_NAME}_private\").IPAddress}}" \
  "$(compose ps --quiet target)")
export TARGET_PRIVATE_IP

run() {
  echo "== phase $1" >&2
  compose run --rm --quiet-pull runner "$1"
}

run wait
run main
run lifecycle

run infra-prepare
compose stop redis
run redis-down
compose start redis
run redis-recovered

compose stop oauth2-proxy
run auth-down
compose start oauth2-proxy
run auth-recovered

run roles-before
# Rewrite in place so the single-file bind mount observes the change.
write_accounts '{"owner@example.test":"member","backup-owner@example.test":"owner"}'
compose restart target
compose up --detach --wait target
run roles-after

run report
