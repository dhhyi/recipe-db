#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <image-reference>" >&2
  exit 2
fi

image=$1
container=production-image-smoke
port=18080
cleanup() {
  docker rm --force "$container" > /dev/null 2>&1 || true
}
trap cleanup EXIT

docker run --detach --rm \
  --name "$container" \
  --publish "127.0.0.1:$port:80" \
  "$image" > /dev/null
if ! curl --fail --silent --show-error --retry 20 --retry-connrefused \
  --retry-delay 1 --max-time 5 "http://127.0.0.1:$port/health"; then
  echo "production image failed its /health smoke check: $image" >&2
  exit 1
fi
