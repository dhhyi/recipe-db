#!/usr/bin/env bats
# Test-local environment overrides are intentional; MOCK_LOG comes from test_helper.
# shellcheck disable=SC2030,SC2031,SC2153

load production-k3d-setup

@test "HTTPS staging rejects unsupported deployment modes before connection" {
  set_value '.httpsStaging={hostname:"recipes.example.org",acmeEnvironment:"production"}'
  run bash .scripts/production-k3d.sh render "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  [[ $output == *"invalid or incomplete production values"* ]]
  run ! grep -q 'kubectl' "$MOCK_LOG"
  run ! grep -q 'oras' "$MOCK_LOG"
}

@test "local rehearsal accepts distinct guarded cluster identities and rejects unrelated names" {
  set_value '.cluster="recipe-db-rehearsal-source" |
    .context="k3d-recipe-db-rehearsal-source" |
    .httpPort=8081 | .apiPort=6446 | .origin="http://127.0.0.1:8081"'
  run bash .scripts/production-k3d.sh render "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  run ! grep -q 'kubectl' "$MOCK_LOG"

  set_value '.cluster="unrelated-cluster" | .context="k3d-unrelated-cluster"'
  run bash .scripts/production-k3d.sh render "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  [[ $output == *"invalid or incomplete production values"* ]]

  set_value '.cluster="recipe-db-rehearsal-target" | .context="k3d-other-cluster"'
  run bash .scripts/production-k3d.sh render "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  [[ $output == *"invalid or incomplete production values"* ]]
  run ! grep -q 'kubectl' "$MOCK_LOG"
}

@test "HTTPS staging rejects unsafe hostname and unknown CA environment before connection" {
  no_google_values
  set_value '.origin="http://recipe-pi.home" | .runtime.ingressMode="private-lan"'
  for change in \
    '.httpsStaging={hostname:"127.0.0.1",acmeEnvironment:"production"}' \
    '.httpsStaging={hostname:"bad`host.example.org",acmeEnvironment:"production"}' \
    '.httpsStaging={hostname:"-bad.example.org",acmeEnvironment:"production"}' \
    '.httpsStaging={hostname:"recipes.example.org",acmeEnvironment:"production",publicApplication:true}' \
    '.httpsStaging={hostname:"recipes.example.org",acmeEnvironment:"unknown"}'; do
    set_value "$change"
    run bash .scripts/production-k3d.sh render "$VALUES" "$ARTIFACT"
    [ "$status" -ne 0 ]
    [[ $output == *"invalid or incomplete production values"* ]]
  done
  run ! grep -q 'kubectl' "$MOCK_LOG"
  run ! grep -q 'oras' "$MOCK_LOG"
}

@test "HTTPS staging refuses unowned ACME storage before mutating the cluster" {
  no_google_values
  set_value '.origin="http://recipe-pi.home" | .runtime.ingressMode="private-lan" |
    .httpsStaging={hostname:"recipes.example.org",acmeEnvironment:"staging"}'
  export MOCK_FOREIGN_ACME=true
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  [[ $output == *"unowned or incompatible ACME claim"* ]]
  run ! grep -q 'create secret' "$MOCK_LOG"
  run ! grep -q 'create -f .*lease.json' "$MOCK_LOG"
}

@test "certificate-only staging routes exclude application and infrastructure endpoints" {
  no_google_values
  set_value '.origin="http://recipe-pi.home" | .runtime.ingressMode="private-lan" |
    .httpsStaging={hostname:"recipes.example.org",acmeEnvironment:"staging"}'
  export MOCK_LAN=true MOCK_HTTPS=true
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  jq -e '
    [to_entries[] | select(.value.entrypoints | index("websecure"))] as $secure |
    ($secure | length) == 1 and $secure[0].key == "https-staging"
    and $secure[0].value.rule == "Host(`recipes.example.org`) && Path(`/`)"
    and $secure[0].value.tls == {certResolver:"letsencrypt",domains:[{main:"recipes.example.org"}]}
    and all(.[]; (.entrypoints | index("staging-http")) == null)
    and .graphql.entrypoints == ["web"]
    and .["graphql-internal"].entrypoints == ["rest-internal"]
  ' "$MOCK_LOG.routers"
  # A stale private-only Service must not be reported as a successful staging rollout.
  export MOCK_HTTPS=false
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  [[ $output == *"requested exposure without NodePorts"* ]]
}

no_google_values() {
  export MOCK_PI=true
  set_value '.target="pi" | .cluster="recipe-db-pi" | .context="explicit-pi" |
    .storageClass="recipe-db-retained" |
    .piStorage={node:"recipe-db-pi",expectedRootUuid:"02f61d5e-92cb-4f9c-a781-099d97795020",dataRoot:"/srv/recipe-db"} |
    .secrets."acme-account-email"=(.secrets."auth-accounts.json" | sub("auth-accounts.json$"; "acme-account-email")) |
    del(.runtime.googleOAuthClientId, .volumes.redis, .infrastructure.oauth2Proxy,
      .infrastructure.redis, .secrets."google-oauth-client-secret", .secrets."oauth2-cookie-secret")'
  printf '{"anonymous":{"role":"anonymous"},"tokens":[{"id":"rehearsal","secret":"private-owner-token","role":"owner"}],"googleAccounts":{}}\n' > auth-accounts.json
}

google_https_values() {
  no_google_values
  set_value '.origin="https://recipes.example.org" |
    .runtime.ingressMode="private-lan" |
    .runtime.googleOAuthClientId="explicit.apps.googleusercontent.com" |
    .volumes.redis="1Gi" |
    .infrastructure.oauth2Proxy="quay.io/oauth2-proxy/oauth2-proxy:v7.9.0" |
    .infrastructure.redis="redis:8.0" |
    .secrets."google-oauth-client-secret"=(.secrets."auth-accounts.json" | sub("auth-accounts.json$"; "google-oauth-client-secret")) |
    .secrets."oauth2-cookie-secret"=(.secrets."auth-accounts.json" | sub("auth-accounts.json$"; "oauth2-cookie-secret")) |
    .httpsStaging={hostname:"recipes.example.org",acmeEnvironment:"production",exposeApplication:true}'
  printf '{"anonymous":{"role":"anonymous"},"tokens":[],"googleAccounts":{}}\n' > auth-accounts.json
}

@test "Google HTTPS preserves optional authentication priorities and private ingress" {
  google_https_values
  export MOCK_LAN=true MOCK_HTTPS=true
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  jq -e '
      . as $routers |
      [to_entries[] | select(.value.entrypoints | index("websecure"))] as $secure |
      ($secure | map(.key) | sort) == ["preview-design","preview-frontend","preview-graphql",
        "preview-graphql-bearer","preview-graphql-cookie","preview-images-edit",
        "preview-images-public","preview-mcp","preview-oauth2-public","preview-recipes-edit"]
      and all($secure[]; .value.middlewares[0] == "identity-strip"
        and .value.tls.certResolver == "letsencrypt")
      and all($secure[]; .key as $name |
        .value.rule == ("Host(`recipes.example.org`) && (" + $routers[($name | ltrimstr("preview-"))].rule + ")"))
      and .["preview-graphql"].priority == 100
      and .["preview-graphql"].middlewares == ["identity-strip","graphql-ingress"]
      and .["preview-graphql-cookie"].priority == 200
      and .["preview-graphql-cookie"].middlewares == ["identity-strip","oauth2-forward-auth","graphql-ingress"]
      and .["preview-graphql-bearer"].priority == 300
      and .["preview-graphql-bearer"].middlewares == ["identity-strip","graphql-ingress"]
      and .["preview-oauth2-public"].priority == 400
      and .["preview-oauth2-public"].middlewares == ["identity-strip"]
      and .["preview-oauth2-public"].rule ==
        "Host(`recipes.example.org`) && (PathRegexp(`^/oauth2/(start|callback|sign_in|sign_out)$`))"
      and .["graphql-internal"].entrypoints == ["rest-internal"]
      and all(.[]; (.entrypoints | index("staging-http")) == null)
  ' "$MOCK_LOG.routers"
  [[ $output != *"private-oauth-client-value-for-tests"* ]]
  [[ $output != *"MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY="* ]]
}

@test "Google HTTPS rejects mismatched origins, untrusted or disabled application exposure before connection" {
  google_https_values
  cp "$VALUES" valid-google-values.json
  for change in \
    '.origin="http://recipe-pi.home"' \
    '.origin="https://different.example.org"' \
    '.origin="https://recipes.example.org:8443"' \
    '.httpsStaging.acmeEnvironment="staging"' \
    '.httpsStaging.exposeApplication=false' \
    'del(.httpsStaging.exposeApplication)' \
    'del(.httpsStaging)' \
    '.runtime.ingressMode="loopback"'; do
    cp valid-google-values.json "$VALUES"
    set_value "$change"
    run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
    [ "$status" -ne 0 ]
    [[ $output == *"invalid or incomplete production values"* ]]
  done
  run ! grep -q 'kubectl' "$MOCK_LOG"
  run ! grep -q 'oras' "$MOCK_LOG"
}

@test "partial and invalid Google configuration and obsolete authMode fail clearly" {
  no_google_values
  cp "$VALUES" valid-no-google-values.json
  for change in \
    '.runtime.googleOAuthClientId=""' \
    '.runtime.googleOAuthClientId="invalid-client-id"' \
    '.runtime.googleOAuthClientId="valid.apps.googleusercontent.com"' \
    '.secrets["google-oauth-client-secret"]="/private/client-secret"' \
    '.secrets["google-oauth-client-secret"]="/private/client-secret" | .secrets["oauth2-cookie-secret"]="/private/cookie-secret"' \
    '.runtime.googleOAuthClientId="valid.apps.googleusercontent.com" | .secrets["google-oauth-client-secret"]="/private/client-secret"'; do
    cp valid-no-google-values.json "$VALUES"
    set_value "$change"
    run bash .scripts/production-k3d.sh render "$VALUES" "$ARTIFACT"
    [ "$status" -ne 0 ]
    [[ $output == *"Google OAuth configuration"* ]]
  done
  cp valid-no-google-values.json "$VALUES"
  set_value '.runtime.authMode="token-only"'
  run bash .scripts/production-k3d.sh render "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  [[ $output == *"runtime.authMode is obsolete"* ]]
  run ! grep -q 'kubectl' "$MOCK_LOG"
  run ! grep -q 'oras' "$MOCK_LOG"
}

@test "Google HTTPS rejects NodePorts and missing HTTPS ports on the actual LoadBalancer" {
  google_https_values
  export MOCK_LAN=true
  for combination in nodeport missing-https; do
    if [[ $combination = nodeport ]]; then
      export MOCK_HTTPS=true MOCK_NODEPORT=true
    else
      export MOCK_HTTPS=false MOCK_NODEPORT=false
    fi
    run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
    [ "$status" -ne 0 ]
    [[ $output == *"ingress does not match the requested exposure without NodePorts"* ]]
  done
}

@test "application exposure is independent of authorization policy" {
  no_google_values
  set_value '.origin="http://recipe-pi.home" | .runtime.ingressMode="private-lan" |
    .httpsStaging={hostname:"recipes.example.org",acmeEnvironment:"production",exposeApplication:true}'
  export MOCK_LAN=true MOCK_HTTPS=true
  for policy in \
    '{"anonymous":{"role":"anonymous"},"tokens":[{"id":"owner","secret":"private-owner-token","role":"owner"}],"googleAccounts":{}}' \
    '{"anonymous":{"role":"owner"},"tokens":[],"googleAccounts":{}}' \
    '{"anonymous":{"role":"anonymous"},"tokens":[],"googleAccounts":{"user@example.org":{"role":"owner"}}}' \
    '{"anonymous":{"role":"anonymous"},"tokens":[],"googleAccounts":{}}'; do
    printf '%s\n' "$policy" > auth-accounts.json
    run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
    [ "$status" -eq 0 ]
    jq -e '.["preview-mcp"].entrypoints == ["websecure"]' "$MOCK_LOG.routers"
  done
  for change in '.httpsStaging.exposeApplication=false' 'del(.httpsStaging.exposeApplication)'; do
    set_value "$change"
    run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
    [ "$status" -eq 0 ]
    jq -e '[to_entries[] | select(.value.entrypoints | index("websecure"))] |
      length == 1 and .[0].key == "https-staging"' "$MOCK_LOG.routers"
  done
}

@test "HTTPS deployment validates private ACME contact and rolls Traefik when it changes" {
  no_google_values
  set_value '.origin="http://recipe-pi.home" | .runtime.ingressMode="private-lan" |
    .httpsStaging={hostname:"recipes.example.org",acmeEnvironment:"production"}'
  for value in '' 'not-an-email' 'acme@example.org
--injected'; do
    printf '%s' "$value" > acme-account-email
    run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
    [ "$status" -ne 0 ]
    [[ $output == *"acme-account-email"* ]]
    [[ $output != *"injected"* ]]
  done
  printf 'acme@example.org\n' > acme-account-email
  export MOCK_LAN=true MOCK_HTTPS=true
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  [[ $output != *"acme@example.org"* ]]
  grep -q 'create secret generic recipe-db-acme-contact' "$MOCK_LOG"
  local original
  original=$(cat "$MOCK_LOG.route-checksum")
  printf 'changed@example.org' > acme-account-email
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  [ "$original" != "$(cat "$MOCK_LOG.route-checksum")" ]
}

@test "HTTPS deployment refuses unowned ACME contact before applying credentials" {
  no_google_values
  set_value '.origin="http://recipe-pi.home" | .runtime.ingressMode="private-lan" |
    .httpsStaging={hostname:"recipes.example.org",acmeEnvironment:"production"}'
  export MOCK_FOREIGN_ACME_CONTACT=true
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  [[ $output == *"unowned ACME contact Secret"* ]]
  run ! grep -q 'create secret' "$MOCK_LOG"
}

@test "preview and renewal rehearsal reject unsafe CA and flag combinations" {
  no_google_values
  set_value '.origin="http://recipe-pi.home" | .runtime.ingressMode="private-lan"'
  for change in \
    '.httpsStaging={hostname:"recipes.example.org",acmeEnvironment:"staging",exposeApplication:true}' \
    '.httpsStaging={hostname:"recipes.example.org",acmeEnvironment:"production",renewalRehearsal:true}' \
    '.httpsStaging={hostname:"recipes.example.org",acmeEnvironment:"production",exposeApplication:"true"}' \
    '.httpsStaging={hostname:"recipes.example.org",acmeEnvironment:"production",readOnlyPreview:true}' \
    '.httpsStaging={hostname:"recipes.example.org",acmeEnvironment:"staging",renewalRehearsal:1}'; do
    set_value "$change"
    run bash .scripts/production-k3d.sh render "$VALUES" "$ARTIFACT"
    [ "$status" -ne 0 ]
    [[ $output == *"invalid or incomplete production values"* ]]
  done
  run ! grep -q 'kubectl' "$MOCK_LOG"
  run ! grep -q 'oras' "$MOCK_LOG"
}

@test "application exposure preserves client routes with sanitized trusted ingress" {
  no_google_values
  printf '{"anonymous":{"role":"anonymous"},"tokens":[],"googleAccounts":{}}\n' > auth-accounts.json
  set_value '.origin="http://recipe-pi.home" | .runtime.ingressMode="private-lan" |
    .httpsStaging={hostname:"recipes.example.org",acmeEnvironment:"production",exposeApplication:true}'
  export MOCK_LAN=true MOCK_HTTPS=true
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  jq -e '
    . as $routers |
    [to_entries[] | select(.value.entrypoints | index("websecure"))] as $secure |
    ($secure | map(.key) | sort) == ["preview-design","preview-frontend","preview-graphql","preview-graphql-bearer","preview-images-edit","preview-images-public","preview-mcp","preview-recipes-edit"]
    and all($secure[]; .value.rule | startswith("Host(`recipes.example.org`) && "))
    and all($secure[]; .value.middlewares[0] == "identity-strip")
    and all($secure[]; .value.tls.certResolver == "letsencrypt")
    and .["preview-graphql"].middlewares == ["identity-strip","graphql-ingress"]
    and .["preview-frontend"].middlewares == ["identity-strip","frontend-compress","browse-unavailable"]
    and all($secure[]; .key as $name |
      .value.rule == ("Host(`recipes.example.org`) && (" + $routers[($name | ltrimstr("preview-"))].rule + ")"))
    and .["preview-recipes-edit"].middlewares == ["identity-strip","recipes-edit-strip"]
    and .["preview-mcp"].service == .mcp.service
    and .["preview-graphql-bearer"].priority == 300
    and .["preview-graphql-bearer"].middlewares == ["identity-strip","graphql-ingress"]
    and .["graphql-cookie"] == null
    and .["oauth2-public"] == null
    and .graphql.entrypoints == ["web"]
    and .["graphql-internal"].entrypoints == ["rest-internal"]
    and all(.[]; (.entrypoints | index("staging-http")) == null)
  ' "$MOCK_LOG.routers"
}

@test "anonymous-only policy deploys without extra flags and survives public shutdown" {
  no_google_values
  printf '{"anonymous":{"role":"anonymous"},"tokens":[],"googleAccounts":{}}\n' > auth-accounts.json
  set_value '.origin="http://recipe-pi.home" | .runtime.ingressMode="private-lan" |
    .httpsStaging={hostname:"recipes.example.org",acmeEnvironment:"production",exposeApplication:true}'
  export MOCK_LAN=true MOCK_HTTPS=true
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  set_value 'del(.httpsStaging)'
  export MOCK_HTTPS=false
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  jq -e 'all(.[]; (.entrypoints | index("websecure")) == null)' "$MOCK_LOG.routers"
  set_value '.runtime.readOnly="true"'
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  [[ $output == *"invalid or incomplete production values"* ]]
}

@test "Google-disabled deployment accepts member tokens without requiring an owner" {
  no_google_values
  printf '{"anonymous":{"role":"anonymous"},"tokens":[{"id":"member","secret":"private-member-token","role":"member"}],"googleAccounts":{}}\n' > auth-accounts.json
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
}

legacy_pi_claims() {
  jq '. as $config | ["recipes","images","tags"] | to_entries | {
    items:map(
      ("00000000-0000-0000-0000-00000000000"+(.key|tostring)) as $uid |
      {apiVersion:"v1",kind:"PersistentVolumeClaim",
        metadata:{name:.value,namespace:"recipe-db",uid:$uid,
          labels:{"app.kubernetes.io/part-of":"recipe-db"}},
        spec:{storageClassName:"local-path",volumeName:("pvc-"+$uid),
          accessModes:["ReadWriteOnce"],volumeMode:"Filesystem",
          resources:{requests:{storage:$config.volumes[.value]}}},
        status:{phase:"Bound"}})
  }' "$VALUES" > "$MOCK_LOG.pvcs"
  jq '{items:[.items[] | {
    apiVersion:"v1",kind:"PersistentVolume",
    metadata:{name:.spec.volumeName,resourceVersion:"1"},
    spec:{storageClassName:"local-path",capacity:{storage:.spec.resources.requests.storage},
      accessModes:["ReadWriteOnce"],volumeMode:"Filesystem",
      persistentVolumeReclaimPolicy:"Retain",
      hostPath:{path:("/srv/recipe-db/storage/"+.spec.volumeName+"_recipe-db_"+.metadata.name)},
      claimRef:{namespace:"recipe-db",name:.metadata.name,uid:.metadata.uid},
      nodeAffinity:{required:{nodeSelectorTerms:[{
        matchExpressions:[{key:"kubernetes.io/hostname",operator:"In",values:["recipe-db-pi"]}]
      }]}}},
    status:{phase:"Bound"}
  }]}' "$MOCK_LOG.pvcs" > "$MOCK_LOG.pvs"
}

@test "Google-disabled Pi deployment requires no OAuth secrets and strips OAuth routing" {
  no_google_values
  rm google-oauth-client-secret oauth2-cookie-secret
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  run ! grep -q -- '--from-file=google-oauth-client-secret' "$MOCK_LOG"
  run ! grep -q -- '--from-file=oauth2-cookie-secret' "$MOCK_LOG"
}

@test "Pi deploy preserves verified legacy bound claim classes before applying manifests" {
  no_google_values
  legacy_pi_claims
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  jq -s -e 'length == 10 and
    all(.[]; .spec.storageClassName ==
      (if .metadata.name == "recipes" or .metadata.name == "images" or .metadata.name == "tags"
       then "local-path" else "recipe-db-retained" end))' "$MOCK_LOG.applied-pvcs"
  run ! grep -q 'patch storageclass' "$MOCK_LOG"
}

@test "Pi backup accepts identity-verified legacy bound claims" {
  export MOCK_BACKUP=true
  no_google_values
  legacy_pi_claims
  run bash .scripts/production-k3d.sh backup "$VALUES" "$ARTIFACT" "$FIXTURE_ROOT/snapshot"
  [ "$status" -eq 0 ]
  [ -f "$FIXTURE_ROOT/snapshot/manifest.json" ]
  run ! grep -q 'patch storageclass' "$MOCK_LOG"
}

@test "Pi backup refuses a legacy claim identity change after storage preflight" {
  export MOCK_BACKUP=true MOCK_PVC_DRIFT=true
  no_google_values
  legacy_pi_claims
  run bash .scripts/production-k3d.sh backup "$VALUES" "$ARTIFACT" "$FIXTURE_ROOT/snapshot"
  [ "$status" -ne 0 ]
  [ ! -e "$FIXTURE_ROOT/snapshot" ]
  run ! grep -Eq 'set env deployment/|exec backup-copy-' "$MOCK_LOG"
}

@test "Google-disabled exposure is independent of origin and authentication mode" {
  no_google_values
  set_value '.origin="http://recipe-pi.home" | .runtime.ingressMode="private-lan"'
  export MOCK_LAN=true
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  jq -e '
    .graphql.entrypoints == ["web"]
    and .["graphql-bearer"].priority == 300
    and .["graphql-cookie"] == null
    and .["oauth2-public"] == null
  ' "$MOCK_LOG.routers"
}

@test "local loopback deploy requires a safe LoadBalancer and managed loopback bindings" {
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  for fault in type nodeport allocate external; do
    export MOCK_SERVICE_TYPE=auto MOCK_NODEPORT=false MOCK_ALLOCATE_NODEPORT=false MOCK_EXTERNAL_IP=false
    case "$fault" in
      type) export MOCK_SERVICE_TYPE=ClusterIP ;;
      nodeport) export MOCK_NODEPORT=true ;;
      allocate) export MOCK_ALLOCATE_NODEPORT=true ;;
      external) export MOCK_EXTERNAL_IP=true ;;
    esac
    run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
    [ "$status" -ne 0 ]
    [[ $output == *"ingress does not match the requested exposure without NodePorts"* ]]
  done
  export MOCK_PUBLIC=true
  : > "$MOCK_LOG"
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  [[ $output == *"loopback-only"* ]]
  run ! grep -q 'apply -f' "$MOCK_LOG"
}

@test "Pi loopback deploy requires ClusterIP and rejects unsafe exposure" {
  no_google_values
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  for fault in type nodeport external; do
    export MOCK_SERVICE_TYPE=auto MOCK_NODEPORT=false MOCK_EXTERNAL_IP=false
    case "$fault" in
      type) export MOCK_SERVICE_TYPE=LoadBalancer ;;
      nodeport) export MOCK_NODEPORT=true ;;
      external) export MOCK_EXTERNAL_IP=true ;;
    esac
    run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
    [ "$status" -ne 0 ]
    [[ $output == *"ingress does not match the requested exposure without NodePorts"* ]]
  done
}

@test "Google-disabled private LAN ingress is explicit and refuses public origins and NodePorts" {
  no_google_values
  set_value '.runtime.ingressMode="private-lan" | .origin="http://recipe-pi.home"'
  export MOCK_LAN=true
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  for origin in http://192.168.1.218 http://10.1.2.3 http://172.16.0.5; do
    ORIGIN="$origin" yq -i '.origin=strenv(ORIGIN)' "$VALUES"
    run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
    [ "$status" -eq 0 ]
  done
  for origin in http://example.com http://8.8.8.8 http://192.168.1.999 http://172.32.0.1 http://recipe-pi.home:8080 https://recipe-pi.home; do
    ORIGIN="$origin" yq -i '.origin=strenv(ORIGIN)' "$VALUES"
    run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
    [ "$status" -ne 0 ]
  done
  set_value '.origin="http://recipe-pi.home"'
  export MOCK_NODEPORT=true
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  [[ $output == *"without NodePorts"* ]]
  export MOCK_NODEPORT=false
  set_value '.runtime.googleOAuthClientId="explicit.apps.googleusercontent.com"'
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  [[ $output == *"Google OAuth configuration"* ]]
}

@test "verify is silent and uses private explicit kubeconfig with live node identity" {
  run bash .scripts/production-k3d.sh verify "$VALUES"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -q 'kubectl --kubeconfig .* --context k3d-recipe-db-rehearsal --namespace recipe-db' "$MOCK_LOG"
  run ! compgen -G '.production-k3d.*'
}

@test "same named foreign cluster cannot be verified or deleted" {
  export MOCK_FOREIGN=true
  run bash .scripts/production-k3d.sh delete "$VALUES" DELETE-recipe-db-rehearsal-AND-ALL-DATA
  [ "$status" -ne 0 ]
  run ! grep -q 'cluster delete' "$MOCK_LOG"
}

@test "create pins server image and maps only loopback ports without touching ambient kubeconfig" {
  export MOCK_ABSENT=true
  run bash .scripts/production-k3d.sh create "$VALUES"
  [ "$status" -eq 0 ]
  grep -q 'cluster create recipe-db-rehearsal --image rancher/k3s:v1.35.5-k3s1 --servers 1 --agents 0' "$MOCK_LOG"
  grep -q -- '--api-port 127.0.0.1:6445 --port 127.0.0.1:8080:80@loadbalancer' "$MOCK_LOG"
  grep -q -- '--runtime-label recipe-db.managed=rehearsal@server:0' "$MOCK_LOG"
  grep -q -- '--kubeconfig-update-default=false --kubeconfig-switch-context=false' "$MOCK_LOG"
}

@test "create refuses insufficient Docker memory before creating cluster" {
  export MOCK_ABSENT=true MOCK_MEMORY=8589934592
  run bash .scripts/production-k3d.sh create "$VALUES"
  [ "$status" -ne 0 ]
  [[ $output == *"more than 8 GiB"* ]]
  run ! grep -q 'cluster create' "$MOCK_LOG"
}

@test "invalid Google OAuth placeholders fail explicitly before application rendering" {
  set_value '.runtime.googleOAuthClientId="replace-with-real-google-oauth-client-id"'
  run bash .scripts/production-k3d.sh render "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  [[ $output == *"Google OAuth configuration"* ]]
  run ! grep -q '^oras' "$MOCK_LOG"
}

@test "existing foreign cluster is never adopted by create" {
  export MOCK_FOREIGN=true
  run bash .scripts/production-k3d.sh create "$VALUES"
  [ "$status" -ne 0 ]
  run ! grep -q 'cluster create' "$MOCK_LOG"
}

@test "managed label does not permit public host port exposure" {
  export MOCK_PUBLIC=true
  run bash .scripts/production-k3d.sh verify "$VALUES"
  [ "$status" -ne 0 ]
  [[ $output == *"loopback-only"* ]]
}

@test "live foreign node identity cannot be used even with managed docker labels" {
  export MOCK_BAD_NODES=true
  run bash .scripts/production-k3d.sh verify "$VALUES"
  [ "$status" -ne 0 ]
  [[ $output == *"live cluster identity mismatch"* ]]
}

@test "delete requires literal cluster data-loss confirmation" {
  run bash .scripts/production-k3d.sh delete "$VALUES" yes
  [ "$status" -ne 0 ]
  [ ! -s "$MOCK_LOG" ]
}

@test "delete removes only verified managed cluster" {
  run bash .scripts/production-k3d.sh delete "$VALUES" DELETE-recipe-db-rehearsal-AND-ALL-DATA
  [ "$status" -eq 0 ]
  grep -q 'k3d cluster delete recipe-db-rehearsal' "$MOCK_LOG"
}

@test "Pi lifecycle and local verification are forbidden" {
  set_value '.target="pi" | .context="explicit-pi" | .storageClass="recipe-db-retained"'
  for action in create verify; do
    run bash .scripts/production-k3d.sh "$action" "$VALUES"
    [ "$status" -ne 0 ]
  done
  run bash .scripts/production-k3d.sh delete "$VALUES" DELETE-recipe-db-rehearsal-AND-ALL-DATA
  [ "$status" -ne 0 ]
  [ ! -s "$MOCK_LOG" ]
}

@test "values reject unknown runtime inputs missing fields and extra durable state" {
  for expression in 'del(.runtime.googleOAuthClientId)' '.runtime.extra="guess"' '.volumes.auth="1Gi"' '.origin="http://0.0.0.0:8080"' '.infrastructure.redis="redis:latest"' '.secrets["graphql-ingress-secret"]="relative"'; do
    cp "$VALUES" values.original
    set_value "$expression"
    run bash .scripts/production-k3d.sh verify "$VALUES"
    [ "$status" -ne 0 ]
    mv values.original "$VALUES"
  done
  [ ! -s "$MOCK_LOG" ]
}

@test "values path must be absolute" {
  run bash .scripts/production-k3d.sh verify values.yaml
  [ "$status" -ne 0 ]
}

@test "Traefik requires sanitizer-capable v3.7 with an explicit Docker Hub digest" {
  for expression in \
    '.infrastructure.traefik="traefik:v3.7.16"' \
    '.infrastructure.traefik="traefik:v3.6.13@sha256:" + ("a"*64)' \
    '.infrastructure.traefik="example.com/traefik:v3.7.16@sha256:" + ("a"*64)' \
    'del(.infrastructure.traefik)'; do
    cp "$VALUES" values.original
    set_value "$expression"
    run bash .scripts/production-k3d.sh verify "$VALUES"
    [ "$status" -ne 0 ]
    [[ $output == *"invalid or incomplete production values"* ]]
    mv values.original "$VALUES"
  done
  [ ! -s "$MOCK_LOG" ]
}

@test "values reject multiple YAML documents" {
  printf '\n---\n{}\n' >> "$VALUES"
  run bash .scripts/production-k3d.sh verify "$VALUES"
  [ "$status" -ne 0 ]
  [[ $output == *"exactly one document"* ]]
  [ ! -s "$MOCK_LOG" ]
}

@test "render requires immutable release repository digest" {
  run bash .scripts/production-k3d.sh render "$VALUES" ghcr.io/dhhyi/recipe-db-releases:latest
  [ "$status" -ne 0 ]
  [ ! -s "$MOCK_LOG" ]
}

@test "render needs no secret files or cluster and prints only nonsecret YAML" {
  rm -f auth-accounts.json graphql-ingress-secret typesense-api-key google-oauth-client-secret oauth2-cookie-secret
  run bash .scripts/production-k3d.sh render "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  [[ $output == "apiVersion: v1"* ]]
  [[ $output != *private-* ]]
  grep -q 'oras pull ghcr.io/dhhyi/recipe-db-releases@sha256:' "$MOCK_LOG"
  run ! grep -Eq '^(k3d|docker|kubectl)' "$MOCK_LOG"
}

@test "driver renders real Kubernetes templates with pinned infrastructure tag and digest refs" {
  cp "$BATS_TEST_DIRNAME/../templates/kubernetes-template.yml" .scripts/templates/
  cp "$BATS_TEST_DIRNAME/../templates/kubernetes.lib.yml" .scripts/templates/
  rm bin/ytt
  set_value '.infrastructure.traefik="traefik:v3.7.16@sha256:1336e85aaed293bd63d005086e0dd013b04078b26aaeb1c18b26a2f928af7e65"'
  run bash .scripts/production-k3d.sh render "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  [[ $output == *"kind: Deployment"* ]]
  [[ $output == *"name: recipe-db-release"* ]]
  [[ $output == *"name: backup-cleanup"* ]]
  [[ $output == *"suspend: true"* ]]
  [[ $output != *"kind: Secret"* ]]
}

@test "artifact traversal is refused before oras pull" {
  export MOCK_SHAPE=true
  run bash .scripts/production-k3d.sh render "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  run ! grep -q 'oras pull' "$MOCK_LOG"
}

@test "render checks every selected immutable image index including attestation-bearing indexes" {
  run bash .scripts/production-k3d.sh render "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^oras manifest fetch ghcr.io/dhhyi/recipe-db-\(recipes\|graphql\)@sha256:' "$MOCK_LOG")" -eq 2 ]
  run ! grep -Eq '^docker (pull|build)' "$MOCK_LOG"
}

@test "incomplete application image index fails before rendering or cluster mutation" {
  export MOCK_INCOMPLETE_INDEX=true
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  [[ $output == *"image index must contain runnable linux/amd64 and linux/arm64 manifests"* ]]
  run ! grep -Eq '^(ytt|kubectl|docker|k3d)' "$MOCK_LOG"
}

@test "guarded kubectl rejects connection overrides" {
  run bash .scripts/production-k3d.sh kubectl "$VALUES" --context foreign get pods
  [ "$status" -ne 0 ]
  run ! grep -q -- '--context foreign' "$MOCK_LOG"
}

@test "deploy creates secrets privately waits NATS init then rollouts and releases lease" {
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  [[ $output != *private-* ]]
  grep -q 'create secret generic recipe-db-runtime' "$MOCK_LOG"
  grep -q -- '--namespace kube-system create secret generic recipe-db-routes' "$MOCK_LOG"
  grep -q 'wait --for=condition=complete job/nats-init --timeout=600s' "$MOCK_LOG"
  grep -q 'delete job nats-init --ignore-not-found --wait=true --timeout=600s' "$MOCK_LOG"
  grep -q -- '--namespace kube-system apply -f .*infrastructure.yml' "$MOCK_LOG"
  grep -q -- '--namespace recipe-db .*apply -f .*application.yml' "$MOCK_LOG"
  run ! grep -q 'rollout restart' "$MOCK_LOG"
  grep -q 'rollout status deployment/recipes --timeout=600s' "$MOCK_LOG"
  grep -q 'rollout status deployment/search --timeout=600s' "$MOCK_LOG"
  grep -q -- '--namespace kube-system rollout status deployment/traefik --timeout=' "$MOCK_LOG"
  grep -q 'delete --raw /apis/coordination.k8s.io/v1/namespaces/kube-system/leases/recipe-db-deploy' "$MOCK_LOG"
  grep -q -- '--namespace kube-system create -f .*recipe-db-deploy-lease.json' "$MOCK_LOG"
  grep -q -- '--namespace kube-system get lease recipe-db-deploy -o json' "$MOCK_LOG"
}

@test "deploy removes the owned cleanup Job and waits for workers before applying a new release" {
  touch "$MOCK_LOG.cleanup-job"
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  [ ! -e "$MOCK_LOG.cleanup-job" ]
  deleted=$(awk '/delete job backup-cleanup / {print NR; exit}' "$MOCK_LOG")
  stopped=$(awk '/get pods -l job-name=backup-cleanup / {print NR; exit}' "$MOCK_LOG")
  applied=$(awk '/apply -f .*application.yml/ {print NR; exit}' "$MOCK_LOG")
  [ "$deleted" -lt "$stopped" ]
  [ "$stopped" -lt "$applied" ]
  run ! grep -q 'patch job backup-cleanup' "$MOCK_LOG"
}

@test "deploy refuses an unowned cleanup Job before applying secrets or workloads" {
  touch "$MOCK_LOG.cleanup-job"
  export MOCK_FOREIGN_CLEANUP=true
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  [[ $output == *"refusing to delete an unowned backup-cleanup Job"* ]]
  [ -e "$MOCK_LOG.cleanup-job" ]
  run ! grep -Eq 'delete job backup-cleanup|create secret|apply -f .*application.yml' "$MOCK_LOG"
  grep -q 'delete --raw /apis/coordination.k8s.io/v1/namespaces/kube-system/leases/recipe-db-deploy' "$MOCK_LOG"
}

@test "deploy stops when cleanup Job deletion fails or workers remain" {
  set_value '.timeoutSeconds=1'
  touch "$MOCK_LOG.cleanup-job"
  export MOCK_CLEANUP_DELETE_FAIL=true
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  [ -e "$MOCK_LOG.cleanup-job" ]
  run ! grep -Eq 'create secret|apply -f .*application.yml' "$MOCK_LOG"

  export MOCK_CLEANUP_DELETE_FAIL=false MOCK_CLEANUP_PODS_REMAIN=true
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  [[ $output == *"cleanup worker Pods remain"* ]]
  run ! grep -Eq 'create secret|apply -f .*application.yml' "$MOCK_LOG"
}

@test "deployment generates fresh internal credentials and rolls dependent workloads" {
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$MOCK_LOG.checksums")" -eq 2 ]
  [ "$(sed -n '1p' "$MOCK_LOG.checksums")" != "$(sed -n '2p' "$MOCK_LOG.checksums")" ]
  [ "$(wc -l < "$MOCK_LOG.typesense-key-checksums")" -eq 2 ]
  [ "$(sed -n '1p' "$MOCK_LOG.typesense-key-checksums")" != "$(sed -n '2p' "$MOCK_LOG.typesense-key-checksums")" ]
  [ "$(sed -n '1p' "$MOCK_LOG.render-checksums")" = "$(sed -n '2p' "$MOCK_LOG.render-checksums")" ]
  [ "$(wc -l < "$MOCK_LOG.route-checksums")" -eq 2 ]
  [ "$(sed -n '1p' "$MOCK_LOG.route-checksums")" != "$(sed -n '2p' "$MOCK_LOG.route-checksums")" ]
  grep -Eq '^[0-9a-f]{64}$' "$MOCK_LOG.checksums"
  run ! grep -q 'rollout restart' "$MOCK_LOG"
  run ! compgen -G '.production-k3d.*'
}

@test "application checksums change when rendered configuration files change" {
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  printf 'updated NATS configuration\n' > message-bus/nats.conf
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  printf 'updated OAuth configuration\n' > oauth2-proxy/oauth2-proxy.cfg
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  printf 'updated maintenance configuration\n' > browse-maintenance/nginx.conf
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$MOCK_LOG.checksums")" -eq 5 ]
  [ "$(sed -n '1p' "$MOCK_LOG.input-checksums")" = "$(sed -n '2p' "$MOCK_LOG.input-checksums")" ]
  [ "$(sed -n '1p' "$MOCK_LOG.input-checksums")" != "$(sed -n '3p' "$MOCK_LOG.input-checksums")" ]
  [ "$(sed -n '3p' "$MOCK_LOG.input-checksums")" != "$(sed -n '4p' "$MOCK_LOG.input-checksums")" ]
  [ "$(sed -n '4p' "$MOCK_LOG.input-checksums")" != "$(sed -n '5p' "$MOCK_LOG.input-checksums")" ]
}

@test "application checksums change when template output changes without input or secret changes" {
  export MOCK_RENDERED_CONFIG=original
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  export MOCK_RENDERED_CONFIG=updated
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$MOCK_LOG.checksums")" -eq 3 ]
  [ "$(sed -n '1p' "$MOCK_LOG.render-checksums")" = "$(sed -n '2p' "$MOCK_LOG.render-checksums")" ]
  [ "$(sed -n '2p' "$MOCK_LOG.render-checksums")" != "$(sed -n '3p' "$MOCK_LOG.render-checksums")" ]
}

@test "existing deployment lease fails closed without deleting another owners lock" {
  export MOCK_LOCK=true
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  [[ $output == *"cannot be acquired"* ]]
  run ! grep -q 'delete lease' "$MOCK_LOG"
  run ! grep -q 'create secret' "$MOCK_LOG"
}

@test "lock status reports the durable cluster operation holder and phase" {
  jq -n '{apiVersion:"coordination.k8s.io/v1",kind:"Lease",
    metadata:{name:"recipe-db-deploy",labels:{"app.kubernetes.io/part-of":"recipe-db"},
      annotations:{"recipe-db/operation":"backup","recipe-db/phase":"capturing"}},
    spec:{holderIdentity:"recipe-db-pi-backup-123"}}' > "$MOCK_LOG.lease"
  run bash .scripts/production-k3d.sh lock-status "$VALUES"
  [ "$status" -eq 0 ]
  [[ $output == *'"holderIdentity": "recipe-db-pi-backup-123"'* ]]
  [[ $output == *'"recipe-db/phase": "capturing"'* ]]
  grep -q -- '--namespace kube-system get lease recipe-db-deploy --ignore-not-found -o json' "$MOCK_LOG"
}

@test "abandoned lock recovery requires exact holder and explicit confirmation" {
  jq -n '{apiVersion:"coordination.k8s.io/v1",kind:"Lease",
    metadata:{name:"recipe-db-deploy",namespace:"kube-system",uid:"lease-uid",resourceVersion:"42",
      labels:{"app.kubernetes.io/part-of":"recipe-db"}},
    spec:{holderIdentity:"recipe-db-pi-backup-123"}}' > "$MOCK_LOG.lease"
  run bash .scripts/production-k3d.sh lock-recover "$VALUES" recipe-db-pi-backup-123 wrong
  [ "$status" -ne 0 ]
  [ -f "$MOCK_LOG.lease" ]
  run ! grep -q 'delete --raw' "$MOCK_LOG"
  run bash .scripts/production-k3d.sh lock-recover "$VALUES" another-holder RECOVER-another-holder
  [ "$status" -ne 0 ]
  [ -f "$MOCK_LOG.lease" ]
  run bash .scripts/production-k3d.sh lock-recover "$VALUES" recipe-db-pi-backup-123 RECOVER-recipe-db-pi-backup-123
  [ "$status" -eq 0 ]
  [ ! -f "$MOCK_LOG.lease" ]
  grep -q -- '--namespace kube-system delete --raw' "$MOCK_LOG"
}

@test "deployment refuses to release a lock whose holder changed" {
  export MOCK_LOCK_OWNER_CHANGE=true
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  [[ $output == *"owner changed"* ]]
  [ -f "$MOCK_LOG.lease" ]
  run ! grep -q 'delete --raw' "$MOCK_LOG"
}

@test "ingress credential rotates on deploy and waits past a stale Traefik checksum" {
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  export MOCK_STALE_ROUTES=true
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  [ "$(sed -n '1p' "$MOCK_LOG.route-checksums")" != "$(sed -n '2p' "$MOCK_LOG.route-checksums")" ]
  [ "$(sed -n '2p' "$MOCK_LOG.route-checksums")" != "$(sed -n '3p' "$MOCK_LOG.route-checksums")" ]
  [ "$(grep -c 'get deployment traefik -o json' "$MOCK_LOG")" -eq 4 ]
  grep -Eq '^[0-9a-f]{64}$' "$MOCK_LOG.route-checksum"
}

@test "deploy refuses a foreign namespace after acquiring and releasing its external lock" {
  export MOCK_FOREIGN_NAMESPACE=true
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  [[ $output == *"unowned application namespace"* ]]
  run ! grep -q 'create secret' "$MOCK_LOG"
  grep -q 'create -f .*recipe-db-deploy-lease.json' "$MOCK_LOG"
  grep -q 'delete --raw.*/leases/recipe-db-deploy' "$MOCK_LOG"
  [ ! -e "$MOCK_LOG.lease" ]
}

@test "deploy refuses foreign Traefik HelmChartConfig before any cluster mutation" {
  export MOCK_FOREIGN_HELM=true
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  [[ $output == *"unowned Traefik HelmChartConfig"* ]]
  run ! grep -q 'create -f' "$MOCK_LOG"
  run ! grep -q 'create secret' "$MOCK_LOG"
}

@test "deploy waits for asynchronous Helm configuration before watching Traefik rollout" {
  export MOCK_HELM_DELAYED=true
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'get deployment traefik -o json' "$MOCK_LOG")" -eq 2 ]
  grep -q -- '--namespace kube-system rollout status deployment/traefik' "$MOCK_LOG"
}

@test "Helm reconciliation timeout fails deploy with safe diagnostics and releases lock" {
  export MOCK_HELM_PENDING=true
  set_value '.timeoutSeconds=1'
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  [[ $output == *"timed out waiting for the configured Traefik"* ]]
  [[ $output == *safe-status* ]]
  grep -q 'delete --raw' "$MOCK_LOG"
}

@test "deployment failure prints safe resource diagnostics and releases lease" {
  export MOCK_ROLLOUT=true
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  [[ $output == *safe-status* ]]
  [[ $output != *private-* ]]
  grep -q 'get events -o custom-columns=TYPE:' "$MOCK_LOG"
  grep -q 'delete --raw' "$MOCK_LOG"
  run ! grep -Eq ' logs |describe|env ' "$MOCK_LOG"
}

@test "deploy validates secret files before connecting or taking lock" {
  printf 'not-json' > auth-accounts.json
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  [[ $output == *"invalid auth-accounts.json"* ]]
  [[ $output != *not-json* ]]
  run ! grep -q '^kubectl' "$MOCK_LOG"
}

@test "secret apply failures never expose kubectl error bodies" {
  export MOCK_SECRET_ERROR=true
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  [[ $output == *"details suppressed to protect secrets"* ]]
  [[ $output != *unsafe-private-secret-contents* ]]
  grep -q 'delete --raw' "$MOCK_LOG"
}

@test "deploy accepts an unpadded URL-safe 32-byte cookie key with a trailing newline" {
  printf '__________________________________________8\n' > oauth2-cookie-secret
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  [[ $output != *"__________________________________________8"* ]]
  grep -q 'create secret generic recipe-db-runtime' "$MOCK_LOG"
}

@test "caller xtrace is disabled before any credentials are processed" {
  run bash -x .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  [[ $output != *private-typesense-value-for-tests* ]]
  [[ $output != *private-oauth-client-value-for-tests* ]]
  [[ $output != *MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=* ]]
  run ! grep -Eq 'private-typesense-value-for-tests|private-oauth-client-value-for-tests' "$MOCK_LOG"
}

@test "deploy normalizes standard padded cookie base64 without modifying operator files" {
  printf '//////////////////////////////////////////8=\n' > oauth2-cookie-secret
  cp oauth2-cookie-secret original-cookie
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  cmp oauth2-cookie-secret original-cookie
  [[ $output != *"//////////////////////////////////////////8="* ]]
}

@test "malformed auth accounts and incorrect ingress token length fail before mutation" {
  printf '[]\n' > auth-accounts.json
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  [[ $output == *"invalid auth-accounts.json"* ]]
  run ! grep -q '^kubectl' "$MOCK_LOG"
}

@test "authorization object policy is left to the authoritative GraphQL runtime validator" {
  printf '{"applicationValidatedPolicy":true}\n' > auth-accounts.json
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  grep -q 'rollout status deployment/recipes --timeout=600s' "$MOCK_LOG"
}

@test "Pi status extracts only its explicitly selected context" {
  no_google_values
  set_value '.target="pi" | .context="explicit-pi" | .storageClass="recipe-db-retained"'
  run bash .scripts/production-k3d.sh status "$VALUES"
  [ "$status" -eq 0 ]
  grep -q '^kubectl --context explicit-pi config view --minify --flatten --raw$' "$MOCK_LOG"
  run ! grep -q '^k3d' "$MOCK_LOG"
}
