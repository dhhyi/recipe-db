#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "$0")/.." && pwd)
umask 077
mkdir -p "$project_root/.secrets"

create_secret() {
  local secret_file=$1 external=$2
  if [ "$external" = true ]; then
    if [ ! -f "$secret_file" ] || [ ! -s "$secret_file" ] || [ ! -r "$secret_file" ]; then
      echo "Configured auth secret must be a readable, nonempty file: $secret_file" >&2
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
      echo "Development auth secret must be a readable, nonempty file: $secret_file" >&2
      exit 1
    fi
    return
  fi
  (
    set -C
    secret=$(dd if=/dev/urandom bs=32 count=1 status=none | base64 | tr '+/' '-_' | tr -d '\n=')
    printf '%s' "$secret" > "$secret_file"
  )
}

google_client_id=${GOOGLE_OAUTH_CLIENT_ID:-}
if [[ -n $google_client_id ]]; then
  [[ $google_client_id =~ ^[a-zA-Z0-9._-]+[.]apps[.]googleusercontent[.]com$ ]] || {
    echo "Invalid GOOGLE_OAUTH_CLIENT_ID" >&2
    exit 1
  }
  client_secret_file=${GOOGLE_OAUTH_CLIENT_SECRET_FILE:-$project_root/.secrets/google-oauth-client-secret}
  create_secret "$client_secret_file" true
  if grep -Fxq 'development-placeholder-not-a-google-secret' "$client_secret_file"; then
    echo "Configured Google OAuth requires a real client secret file: $client_secret_file" >&2
    exit 1
  fi
  client_secret_size=$(wc -c < "$client_secret_file")
  client_secret_printable=$(LC_ALL=C tr -cd '!-~' < "$client_secret_file" | wc -c)
  if ((client_secret_size < 16)) || ((client_secret_size != client_secret_printable)); then
    echo "Invalid Google OAuth client secret file: $client_secret_file" >&2
    exit 1
  fi
  cookie_secret_file=${OAUTH2_COOKIE_SECRET_FILE:-$project_root/.secrets/oauth2-cookie-secret}
  create_secret "$cookie_secret_file" \
    "${OAUTH2_COOKIE_SECRET_FILE:+true}"
  cookie_secret=$(< "$cookie_secret_file")
  [[ $cookie_secret =~ ^[A-Za-z0-9_-]+$ ]] || {
    echo "Invalid OAuth2 Proxy cookie secret file: $cookie_secret_file" >&2
    exit 1
  }
  standard_cookie=${cookie_secret//_/\/}
  standard_cookie=${standard_cookie//-/+}
  while ((${#standard_cookie} % 4 != 0)); do standard_cookie+='='; done
  cookie_bytes=$(printf '%s' "$standard_cookie" | base64 -d 2> /dev/null | wc -c)
  [[ $cookie_bytes = 16 || $cookie_bytes = 24 || $cookie_bytes = 32 ]] || {
    echo "Invalid OAuth2 Proxy cookie secret file: $cookie_secret_file" >&2
    exit 1
  }
elif [[ -n ${GOOGLE_OAUTH_CLIENT_SECRET_FILE:-} || -n ${OAUTH2_COOKIE_SECRET_FILE:-} ]]; then
  echo "Google OAuth secret paths require GOOGLE_OAUTH_CLIENT_ID" >&2
  exit 1
fi
create_secret "${GRAPHQL_INGRESS_SECRET_FILE:-$project_root/.secrets/graphql-ingress-secret}" \
  "${GRAPHQL_INGRESS_SECRET_FILE:+true}"
