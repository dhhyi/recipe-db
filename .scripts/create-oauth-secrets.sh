#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "$0")/.." && pwd)
umask 077
mkdir -p "$project_root/.secrets"

create_secret() {
  local secret_file=$1 secret_kind=$2 external=$3
  if [ "$external" = true ]; then
    if [ ! -f "$secret_file" ] || [ ! -s "$secret_file" ] || [ ! -r "$secret_file" ]; then
      echo "Configured OAuth secret must be a readable, nonempty file: $secret_file" >&2
      exit 1
    fi
    return
  fi
  if [ -d "$secret_file" ]; then
    echo "Removing empty Docker-created secret directory: $secret_file" >&2
    rmdir "$secret_file"
  fi
  if [ -e "$secret_file" ]; then
    if [ ! -f "$secret_file" ] || [ ! -s "$secret_file" ] || [ ! -r "$secret_file" ]; then
      echo "Development OAuth secret must be a readable, nonempty file: $secret_file" >&2
      exit 1
    fi
    return
  fi
  (
    set -C
    if [ "$secret_kind" = cookie ]; then
      secret=$(dd if=/dev/urandom bs=32 count=1 status=none | base64)
      printf '%s' "$secret" > "$secret_file"
    else
      printf '%s' 'development-placeholder-not-a-google-secret' > "$secret_file"
    fi
  )
}

create_secret "${GOOGLE_OAUTH_CLIENT_SECRET_FILE:-$project_root/.secrets/google-oauth-client-secret}" \
  client "${GOOGLE_OAUTH_CLIENT_SECRET_FILE:+true}"
create_secret "${OAUTH2_COOKIE_SECRET_FILE:-$project_root/.secrets/oauth2-cookie-secret}" \
  cookie "${OAUTH2_COOKIE_SECRET_FILE:+true}"
