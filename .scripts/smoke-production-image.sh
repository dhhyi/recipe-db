#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <image-reference>" >&2
  exit 2
fi

image=$1
container=production-image-smoke
port=18080
temporary_directory=$(mktemp -d)
trap 'docker rm --force "$container" > /dev/null 2>&1 || true; rm -rf "$temporary_directory"' EXIT

docker run --detach \
  --name "$container" \
  --publish "127.0.0.1:$port:80" \
  "$image" > /dev/null

attempt=1
while [ "$attempt" -le 30 ]; do
  if curl --fail --silent --show-error --connect-timeout 1 --max-time 5 \
    "http://127.0.0.1:$port/health" 2> "$temporary_directory/curl-error"; then
    exit 0
  fi
  sleep 1
  attempt=$((attempt + 1))
done

cat "$temporary_directory/curl-error" >&2
docker logs "$container" >&2 || true
echo "production image failed its /health smoke check: $image" >&2
exit 1
