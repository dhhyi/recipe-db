#!/bin/sh

if [ -z "$REST_API" ]; then
  echo "REST_API is not set"
  exit 1
fi

if [ -z "$1" ]; then
  tests="."
else
  tests="$*"
fi

exec venom run --var REST_API="$REST_API" --stop-on-failure $tests
