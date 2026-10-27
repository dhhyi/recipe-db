#!/usr/bin/env bash
# Variables are shared with the sourcing lifecycle driver.
# shellcheck disable=SC2034,SC2154

production_fail() {
  printf 'production: %s\n' "$*" >&2
  exit 1
}

production_config() {
  [[ $1 = /* && -f $1 ]] || production_fail "values must be an absolute file path"
  yq -o=json eval-all '[.]' "$1" > "$work/config-documents.json"
  jq -e 'if length == 1 then .[0] else error("expected one values document") end' \
    "$work/config-documents.json" > "$work/config.json" \
    || production_fail "values must contain exactly one document"
  jq -e --arg action "$2" '
    def objectkeys($expected): type == "object" and (keys == ($expected | sort));
    def nonempty: type == "string" and length > 0;
    def name: type == "string" and test("^[a-z][a-z0-9-]{0,61}[a-z0-9]$");
    def quantity: type == "string" and test("^[1-9][0-9]*(Mi|Gi)$");
    def image: type == "string" and
      test("^[a-zA-Z0-9./_-]+(:[a-zA-Z0-9_.-]+)?@sha256:[0-9a-f]{64}$|^[a-zA-Z0-9./_-]+:[a-zA-Z0-9_.-]+$") and
      (endswith(":latest") | not);
    objectkeys(["target","cluster","context","namespace","origin","httpPort","apiPort",
      "timeoutSeconds","storageClass","volumes","resources","infrastructure","runtime","secrets"])
    and ([.. | strings] | all(.[]; test("[[:cntrl:]]") | not))
    and (.target == "local" or .target == "pi")
    and (.cluster | name) and (.namespace == "recipe-db")
    and (.context | nonempty) and (.storageClass | name)
    and (.httpPort | type == "number" and floor == . and . > 1024 and . <= 65535)
    and (.apiPort | type == "number" and floor == . and . > 1024 and . <= 65535)
    and .httpPort != .apiPort
    and (.timeoutSeconds | type == "number" and floor == . and . >= 1 and . <= 3600)
    and (.origin | type == "string" and test("^https?://[a-zA-Z0-9.-]+(:[0-9]+)?$"))
    and (if .target == "local" then
      .cluster == "recipe-db-rehearsal" and .context == "k3d-recipe-db-rehearsal"
      and .origin == ("http://127.0.0.1:" + (.httpPort | tostring))
      and .storageClass == "local-path"
    else .context != "k3d-recipe-db-rehearsal" end)
    and (.volumes | objectkeys(["recipes","images","ratings","inspirations","nats","typesense","search","redis"])
      and all(.[]; quantity))
    and (.resources | objectkeys(["requests","limits"])
      and (.requests | objectkeys(["cpu","memory"])
        and (.cpu | type == "string" and test("^[1-9][0-9]*m$"))
        and (.memory | quantity))
      and (.limits | objectkeys(["memory"]) and (.memory | quantity)))
    and (.infrastructure | objectkeys(["traefik","nats","typesense","maintenance","oauth2Proxy","redis"])
      and all(.[]; image)
      and (.traefik | test("^traefik:v3[.]7[.][0-9]+@sha256:[0-9a-f]{64}$")))
    and (.runtime | objectkeys(["googleOAuthClientId","trustedIssuer"])
      and (.googleOAuthClientId | nonempty and
        (if $action == "render" or $action == "deploy" then
          test("^[a-zA-Z0-9._-]+[.]apps[.]googleusercontent[.]com$")
        else true end))
      and .trustedIssuer == "https://accounts.google.com")
    and (.secrets | objectkeys(["auth-accounts.json","graphql-ingress-secret","typesense-api-key",
        "google-oauth-client-secret","oauth2-cookie-secret"])
      and all(.[]; type == "string" and startswith("/") and (test("[\\r\\n]") | not)))
  ' "$work/config.json" > /dev/null || production_fail "invalid or incomplete production values"
  target=$(jq -r .target "$work/config.json")
  cluster=$(jq -r .cluster "$work/config.json")
  context=$(jq -r .context "$work/config.json")
  namespace=$(jq -r .namespace "$work/config.json")
  http_port=$(jq -r .httpPort "$work/config.json")
  api_port=$(jq -r .apiPort "$work/config.json")
  timeout=$(jq -r .timeoutSeconds "$work/config.json")
}

production_secrets() {
  local key path decoded cookie
  for key in auth-accounts.json graphql-ingress-secret typesense-api-key google-oauth-client-secret oauth2-cookie-secret; do
    path=$(jq -r --arg key "$key" '.secrets[$key]' "$work/config.json")
    [[ -f $path && -r $path && -s $path ]] || production_fail "missing or unreadable secret file: $key"
    # Copy once: secret validation, route rendering and Secret creation use the same bytes.
    cp -- "$path" "$work/$key"
  done
  # GraphQL is the sole authorization-policy validator; deployment only checks the envelope.
  jq -se 'length == 1 and (.[0] | type == "object")' "$work/auth-accounts.json" > /dev/null 2>&1 \
    || production_fail "invalid auth-accounts.json (expected one JSON object)"
  jq -eRs 'test("^[A-Za-z0-9_-]{43}\\n?\\z")' "$work/graphql-ingress-secret" > /dev/null \
    || production_fail "invalid secret format: graphql-ingress-secret (expected 43 URL-safe base64 characters)"
  for key in typesense-api-key google-oauth-client-secret; do
    jq -eRs 'length >= 16 and (test("^[!-~]+\\n?\\z"))' "$work/$key" > /dev/null \
      || production_fail "invalid secret format: $key"
  done
  jq -eRs 'test("^[A-Za-z0-9+/_-]+={0,2}\\n?\\z")' "$work/oauth2-cookie-secret" > /dev/null \
    || production_fail "invalid oauth2 cookie secret"
  cookie=$(< "$work/oauth2-cookie-secret")
  cookie=${cookie//_/\/}
  cookie=${cookie//-/+}
  while ((${#cookie} % 4 != 0)); do
    cookie+='='
  done
  decoded=$(printf '%s' "$cookie" | base64 -d 2> /dev/null | wc -c) \
    || production_fail "oauth2 cookie secret must be base64"
  [[ $decoded = 16 || $decoded = 24 || $decoded = 32 ]] \
    || production_fail "oauth2 cookie secret must encode 16, 24 or 32 bytes"
  # OAuth2 Proxy decodes only URL-safe base64, with no trailing newline.
  printf '%s' "$cookie" | tr '/+' '_-' | tr -d '=' > "$work/oauth2-cookie-secret"
}
