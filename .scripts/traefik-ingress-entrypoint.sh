#!/bin/sh
set -eu

secret=$(cat /run/secrets/graphql-ingress-secret)
case "$secret" in
  '' | *[!A-Za-z0-9_-]*)
    echo "GraphQL ingress secret must be 43 URL-safe base64 characters" >&2
    exit 1
    ;;
esac
if [ "${#secret}" -ne 43 ]; then
  echo "GraphQL ingress secret must be 43 URL-safe base64 characters" >&2
  exit 1
fi

umask 077
cp /traefik_config.yml /run/traefik/routes.yml
cat > /run/traefik/ingress.yml << EOF
http:
  middlewares:
    graphql-ingress:
      headers:
        customRequestHeaders:
          X-Internal-Ingress-Token: "$secret"
EOF
unset secret
exec /entrypoint.sh "$@"
