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
  if jq -e '(.runtime | type == "object" and has("authMode"))' "$work/config.json" > /dev/null 2>&1; then
    production_fail "runtime.authMode is obsolete; omit it and configure Google OAuth with a client ID and both OAuth secret paths"
  fi
  local google_fields
  google_fields=$(jq -r '
    ((.runtime | type == "object" and has("googleOAuthClientId")) or
     (.secrets | type == "object" and
       (has("google-oauth-client-secret") or has("oauth2-cookie-secret"))))
  ' "$work/config.json")
  google_enabled=false
  if [[ $google_fields = true ]]; then
    jq -e '
      (.runtime | type == "object" and has("googleOAuthClientId") and
        (.googleOAuthClientId | type == "string" and
          test("^[a-zA-Z0-9._-]+[.]apps[.]googleusercontent[.]com$"))) and
      (.secrets | type == "object" and has("google-oauth-client-secret") and
        has("oauth2-cookie-secret"))
    ' "$work/config.json" > /dev/null \
      || production_fail "incomplete or invalid Google OAuth configuration; provide a valid client ID and both OAuth secret paths, or omit all three"
    google_enabled=true
  fi
  jq -e --arg action "$2" --argjson googleEnabled "$google_enabled" '
    def objectkeys($expected): type == "object" and (keys == ($expected | sort));
    def nonempty: type == "string" and length > 0;
    def name: type == "string" and test("^[a-z][a-z0-9-]{0,61}[a-z0-9]$");
    def quantity: type == "string" and test("^[1-9][0-9]*(Mi|Gi)$");
    def image: type == "string" and
      test("^[a-zA-Z0-9./_-]+(:[a-zA-Z0-9_.-]+)?@sha256:[0-9a-f]{64}$|^[a-zA-Z0-9./_-]+:[a-zA-Z0-9_.-]+$") and
      (endswith(":latest") | not);
    def private_lan_origin:
      sub("^http://"; "") as $host |
      test("^http://[a-zA-Z0-9][a-zA-Z0-9.-]*[.](home|lan|local)$") or
      (try ($host | split(".") | map(tonumber) |
        length == 4 and all(.[]; floor == . and . >= 0 and . <= 255) and
        (.[0] == 10 or (.[0] == 192 and .[1] == 168) or
          (.[0] == 172 and .[1] >= 16 and .[1] <= 31))) catch false);
    objectkeys(["target","cluster","context","namespace","origin","httpPort","apiPort",
      "timeoutSeconds","storageClass","volumes","resources","infrastructure","runtime","secrets"] +
      (if has("piStorage") then ["piStorage"] else [] end) +
      (if has("httpsStaging") then ["httpsStaging"] else [] end))
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
      (.cluster == "recipe-db-rehearsal" or
        (.cluster | test("^recipe-db-rehearsal-[a-z0-9][a-z0-9-]*$")))
      and .context == ("k3d-" + .cluster)
      and .origin == ("http://127.0.0.1:" + (.httpPort | tostring))
      and .storageClass == "local-path"
    else .context != "k3d-recipe-db-rehearsal" and .storageClass == "recipe-db-retained" end)
    and (if has("piStorage") then
      .target == "pi" and
      (.piStorage | objectkeys(["node","expectedRootUuid","dataRoot"])
        and (.node | name) and (.expectedRootUuid | nonempty)
        and (.dataRoot | type == "string" and test("^/srv/[a-zA-Z0-9_-]+$")))
      else true end)
    and (if .target == "pi" and
      ($action == "deploy" or $action == "backup-run" or $action == "backup-enter"
        or $action == "backup-capture" or $action == "backup-exit"
        or $action == "release-stage" or $action == "release-migration-result"
        or $action == "release-start" or $action == "release-reopen"
        or $action == "release-disposition" or $action == "restore" or $action == "storage-reattach")
      then has("piStorage")
        and .piStorage.node == .cluster
        and (.piStorage.expectedRootUuid | test("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$"))
      else true end)
    and (if $action == "storage-reattach" then .target == "pi" else true end)
    and (.volumes | objectkeys(["recipes","images","ratings","inspirations","image-inline","link-extract",
      "nats","typesense","search","tags"] + (if $googleEnabled then ["redis"] else [] end))
      and all(.[]; quantity))
    and (.resources | objectkeys(["requests","limits"])
      and (.requests | objectkeys(["cpu","memory"])
        and (.cpu | type == "string" and test("^[1-9][0-9]*m$"))
        and (.memory | quantity))
      and (.limits | objectkeys(["memory"]) and (.memory | quantity)))
    and (.infrastructure | objectkeys(["traefik","nats","typesense","maintenance"] +
      (if $googleEnabled then ["oauth2Proxy","redis"] else [] end))
      and all(.[]; image)
      and (.traefik | test("^traefik:v3([.]([7-9]|[1-9][0-9])([.][0-9]+)?)?@sha256:[0-9a-f]{64}$")))
    and (.runtime | objectkeys(["trustedIssuer"] +
      (if has("ingressMode") then ["ingressMode"] else [] end) +
      (if $googleEnabled then ["googleOAuthClientId"] else [] end))
      and ((.ingressMode // "loopback") == "loopback" or .ingressMode == "private-lan")
      and .trustedIssuer == "https://accounts.google.com")
    and (if .runtime.ingressMode == "private-lan" then
      .target == "pi" and
      (if has("httpsStaging") then
        ((.origin | private_lan_origin) or .origin == ("https://" + .httpsStaging.hostname))
       else (.origin | private_lan_origin) end)
      else true end)
    and (if $googleEnabled and .target == "pi" then
      has("httpsStaging") and .runtime.ingressMode == "private-lan"
      and .origin == ("https://" + .httpsStaging.hostname)
      and .httpsStaging.acmeEnvironment == "production"
      and .httpsStaging.exposeApplication == true
      else true end)
    and (if has("httpsStaging") then
      .target == "pi"
      and .runtime.ingressMode == "private-lan" and has("piStorage")
      and (.httpsStaging | objectkeys(["hostname","acmeEnvironment"] +
        (if has("exposeApplication") then ["exposeApplication"] else [] end) +
        (if has("renewalRehearsal") then ["renewalRehearsal"] else [] end))
        and (.hostname | type == "string" and length <= 253
          and test("^[a-z0-9]([a-z0-9-]*[a-z0-9])?([.][a-z0-9]([a-z0-9-]*[a-z0-9])?)+$")
          and (split(".") | all(.[]; length <= 63))
          and (test("^[0-9.]+$") | not))
        and (.acmeEnvironment == "staging" or .acmeEnvironment == "production")
        and (if has("exposeApplication") then
          (.exposeApplication | type == "boolean") and
          (if .exposeApplication then .acmeEnvironment == "production" else true end)
          else true end)
        and (if has("renewalRehearsal") then
          (.renewalRehearsal | type == "boolean") and
          (if .renewalRehearsal then .acmeEnvironment == "staging" else true end)
          else true end))
      else true end)
    and (if has("httpsStaging") then .secrets | has("acme-account-email") else true end)
    and (.secrets |
      objectkeys(["auth-accounts.json"] +
        (if $googleEnabled then ["google-oauth-client-secret","oauth2-cookie-secret"] else [] end) +
        (if has("acme-account-email") then ["acme-account-email"] else [] end))
      and all(.[]; type == "string" and startswith("/") and (test("[\\r\\n]") | not)))
  ' "$work/config.json" > /dev/null \
    || production_fail "invalid or incomplete production values"
  target=$(jq -r .target "$work/config.json")
  cluster=$(jq -r .cluster "$work/config.json")
  context=$(jq -r .context "$work/config.json")
  namespace=$(jq -r .namespace "$work/config.json")
  http_port=$(jq -r .httpPort "$work/config.json")
  api_port=$(jq -r .apiPort "$work/config.json")
  timeout=$(jq -r .timeoutSeconds "$work/config.json")
  storage_class=$(jq -r .storageClass "$work/config.json")
  storage_node=$(jq -r '.piStorage.node // empty' "$work/config.json")
  storage_root_uuid=$(jq -r '.piStorage.expectedRootUuid // empty' "$work/config.json" | tr '[:upper:]' '[:lower:]')
  storage_data_root=$(jq -r '.piStorage.dataRoot // empty' "$work/config.json")
  ingress_mode=$(jq -r '.runtime.ingressMode // "loopback"' "$work/config.json")
  acme_email_path=$(jq -r '.secrets["acme-account-email"] // empty' "$work/config.json")
  secret_keys=(auth-accounts.json graphql-ingress-secret typesense-api-key)
  operator_secret_keys=(auth-accounts.json)
  if $google_enabled; then
    secret_keys+=(google-oauth-client-secret oauth2-cookie-secret)
    operator_secret_keys+=(google-oauth-client-secret oauth2-cookie-secret)
  fi
}

production_secrets() {
  local key path decoded cookie
  for key in "${operator_secret_keys[@]}"; do
    path=$(jq -r --arg key "$key" '.secrets[$key]' "$work/config.json")
    [[ -f $path && -r $path && -s $path ]] || production_fail "missing or unreadable secret file: $key"
    # Copy once: secret validation, route rendering and Secret creation use the same bytes.
    cp -- "$path" "$work/$key"
  done
  if jq -e 'has("httpsStaging")' "$work/config.json" > /dev/null; then
    [[ -f $acme_email_path && -r $acme_email_path && -s $acme_email_path ]] \
      || production_fail "missing or unreadable secret file: acme-account-email"
    cp -- "$acme_email_path" "$work/acme-account-email"
    jq -eRs '
      length <= 255 and
      test("^[A-Za-z0-9._%+-]+@[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?([.][A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+\\n?\\z")
    ' "$work/acme-account-email" > /dev/null \
      || production_fail "invalid secret format: acme-account-email"
    tr -d '\n' < "$work/acme-account-email" > "$work/acme-email-normalized"
    mv "$work/acme-email-normalized" "$work/acme-account-email"
  fi
  # GraphQL is the sole authorization-policy validator; deployment only checks the envelope.
  jq -se 'length == 1 and (.[0] | type == "object")' "$work/auth-accounts.json" > /dev/null 2>&1 \
    || production_fail "invalid auth-accounts.json (expected one JSON object)"
  for key in "${operator_secret_keys[@]:1}"; do
    [[ $key != oauth2-cookie-secret ]] || continue
    jq -eRs 'length >= 16 and (test("^[!-~]+\\n?\\z"))' "$work/$key" > /dev/null \
      || production_fail "invalid secret format: $key"
  done
  $google_enabled || return 0
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

production_ephemeral_secrets() {
  openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n' > "$work/graphql-ingress-secret" \
    || production_fail "could not generate the deployment ingress credential"
  openssl rand -hex 32 > "$work/typesense-api-key" \
    || production_fail "could not generate the deployment Typesense credential"
  jq -eRs 'test("^[A-Za-z0-9_-]{43}\\z")' "$work/graphql-ingress-secret" > /dev/null \
    || production_fail "generated deployment ingress credential is invalid"
  jq -eRs 'test("^[0-9a-f]{64}\\n?\\z")' "$work/typesense-api-key" > /dev/null \
    || production_fail "generated deployment Typesense credential is invalid"
}
