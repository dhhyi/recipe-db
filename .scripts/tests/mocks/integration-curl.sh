#!/usr/bin/env bash
set -euo pipefail

method=
for argument in "$@"; do
  if [[ $argument == --head ]]; then method=" HEAD"; fi
  url=$argument
done
printf 'curl%s %s\n' "$method" "$url" >> "$MOCK_LOG"
if [[ ${CURL_FAIL_ONCE:-false} == true && ! -e "$MOCK_LOG.curl-failed" ]]; then
  touch "$MOCK_LOG.curl-failed"
  exit 7
fi
case "$url" in
  */design/styles.css) printf 302 ;;
  */images/nonexistent/meta) printf '404 application/problem+json' ;;
  */inspirations)
    if [[ -n ${INSPIRATIONS_NOT_READY_ONCE:-} && ! -e "$MOCK_LOG.inspirations-not-ready" ]]; then
      touch "$MOCK_LOG.inspirations-not-ready"
      printf '%s' "$INSPIRATIONS_NOT_READY_ONCE"
    else
      printf 204
    fi
    ;;
  */link-extract | */image-inline/) printf 400 ;;
  *) printf 200 ;;
esac
