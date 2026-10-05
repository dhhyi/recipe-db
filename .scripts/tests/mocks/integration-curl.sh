#!/usr/bin/env bash
set -euo pipefail

for argument in "$@"; do
  url=$argument
done
printf 'curl %s\n' "$url" >> "$MOCK_LOG"
if [[ ${CURL_FAIL_ONCE:-false} == true && ! -e "$MOCK_LOG.curl-failed" ]]; then
  touch "$MOCK_LOG.curl-failed"
  exit 7
fi
case "$url" in
  */images/nonexistent/meta) printf 'Not found\n404' ;;
  */link-extract | */image-inline/) printf 400 ;;
  *) printf 200 ;;
esac
