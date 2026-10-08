#!/bin/sh
set -eu

project_root=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$project_root"
name=recipe-db-message-bus-test-$$
container_started=false
volume_created=false

cleanup() {
  status=$?
  trap - 0
  if [ "$container_started" = true ]; then
    docker logs "$name" >&2 || status=1
    docker rm -f "$name" >&2 || status=1
  fi
  if [ "$volume_created" = true ]; then
    docker volume rm "$name" >&2 || status=1
  fi
  exit "$status"
}
trap cleanup 0
trap 'exit 130' 2
trap 'exit 143' 15

mise run --raw create-intranet
if docker container inspect "$name" > /dev/null 2>&1 || docker volume inspect "$name" > /dev/null 2>&1; then
  echo "Refusing to reuse existing test resources: $name" >&2
  exit 1
fi
docker volume create "$name" > /dev/null
volume_created=true
docker create --name "$name" --network intranet --network-alias "$name" \
  --env "VERBOSE=${VERBOSE:-false}" \
  --mount "type=bind,src=$project_root/message-bus/nats.conf,dst=/etc/nats/nats.conf,readonly" \
  --mount "type=volume,src=$name,dst=/data" \
  nats:2.11.10-alpine --config /etc/nats/nats.conf
container_started=true
docker start "$name" > /dev/null

wait_for_broker() {
  attempt=0
  until docker exec "$name" wget -q -O /dev/null 'http://127.0.0.1:8222/healthz?js-enabled-only=true'; do
    if [ "$(docker inspect --format '{{.State.Running}}' "$name")" != true ]; then
      echo "Message bus exited during startup" >&2
      return 1
    fi
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 30 ]; then
      echo "Message bus did not become healthy" >&2
      return 1
    fi
    sleep 1
  done
}

run_test() {
  mise run --raw in-devcontainer graphql \
    "env NATS_TEST_URL=nats://$name:4222 cargo test $1 -- --ignored --nocapture"
}

wait_for_broker
run_test bus_contract
docker stop "$name" > /dev/null
run_test bus_outage_preserves_mutation_results
docker start "$name" > /dev/null
wait_for_broker
run_test bus_restart_recovery
