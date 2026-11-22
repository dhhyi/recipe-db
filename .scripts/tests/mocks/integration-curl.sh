#!/usr/bin/env bash
set -euo pipefail

method=
data=
previous=
for argument in "$@"; do
  if [[ $argument == --head ]]; then method=" HEAD"; fi
  if [[ $previous == --data ]]; then
    method=" POST"
    data=" $argument"
  fi
  previous=$argument
  url=$argument
done
printf 'curl%s %s%s\n' "$method" "$url" "$data" >> "$MOCK_LOG"
if [[ ${CURL_FAIL_ONCE:-false} == true && ! -e "$MOCK_LOG.curl-failed" ]]; then
  touch "$MOCK_LOG.curl-failed"
  exit 7
fi
if [[ $method == " HEAD" && -n ${HEAD_RESPONSE:-} ]]; then
  printf '%s' "$HEAD_RESPONSE"
  exit 0
fi
if [[ $url == http://127.0.0.1:3000/search && $method == " POST" ]]; then
  if [[ -n ${SEARCH_RESPONSE:-} ]]; then
    printf '%s' "$SEARCH_RESPONSE"
  elif [[ -n ${SEARCH_NOT_READY_ONCE:-} && ! -e "$MOCK_LOG.search-not-ready" ]]; then
    touch "$MOCK_LOG.search-not-ready"
    printf '%s' "$SEARCH_NOT_READY_ONCE"
  else
    printf 200
  fi
  exit 0
fi
case "$url" in
  */design/styles.css) printf 302 ;;
  http://127.0.0.1:3000/images | \
    http://127.0.0.1:3000/link-extract | \
    http://127.0.0.1:3000/image-inline/ | \
    http://127.0.0.1:3000/recipes | \
    http://127.0.0.1:3000/ratings | \
    http://127.0.0.1:3000/inspirations | \
    http://127.0.0.1:3000/search | \
    http://127.0.0.1:8080/graphql | \
    http://127.0.0.1:8080/mcp | \
    http://127.0.0.1:8080/)
    if [[ $method == " HEAD" ]]; then
      if [[ $url == */inspirations && -n ${INSPIRATIONS_NOT_READY_ONCE:-} && ! -e "$MOCK_LOG.inspirations-not-ready" ]]; then
        touch "$MOCK_LOG.inspirations-not-ready"
        printf '%s' "$INSPIRATIONS_NOT_READY_ONCE"
      else
        printf 204
      fi
    else
      printf 200
    fi
    ;;
  */inspirations)
    if [[ -n ${INSPIRATIONS_NOT_READY_ONCE:-} && ! -e "$MOCK_LOG.inspirations-not-ready" ]]; then
      touch "$MOCK_LOG.inspirations-not-ready"
      printf '%s' "$INSPIRATIONS_NOT_READY_ONCE"
    else
      printf 204
    fi
    ;;
  */graphql-test-fixture/ | */link-extract-test-fixture/page | \
    */image-inline-test-fixture/tiny.png | */mcp-test-fixture/test.jpg) printf 200 ;;
  *) printf 200 ;;
esac
