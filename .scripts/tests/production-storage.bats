#!/usr/bin/env bats

load test_helper

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  source "$ROOT/.scripts/lib/production-config.sh"
  source "$ROOT/.scripts/lib/production-storage.sh"
  work="$BATS_TEST_TMPDIR/work"
  mkdir -p "$work"
  target=pi
  context=recipe-db-pi
  namespace=recipe-db
  storage_class=local-path
  storage_node=recipe-db-pi
  storage_root_uuid=02f61d5e-92cb-4f9c-a781-099d97795020
  storage_data_root=/srv/recipe-db
  timeout=30
  cluster_operation_lock_holder=storage-test
  export MOCK_KUBE_CALLS="$BATS_TEST_TMPDIR/kube-calls"
  : > "$MOCK_KUBE_CALLS"
  jq -n '{
    target:"pi",cluster:"recipe-db-pi",namespace:"recipe-db",storageClass:"local-path",
    piStorage:{node:"recipe-db-pi",expectedRootUuid:"02f61d5e-92cb-4f9c-a781-099d97795020",dataRoot:"/srv/recipe-db"},
    volumes:{recipes:"1Gi"},
    infrastructure:{maintenance:"nginx:stable-alpine@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
    resources:{requests:{cpu:"25m",memory:"32Mi"},limits:{memory:"512Mi"}}
  }' > "$work/config.json"
}

cluster_operation_lock_status() {
  jq -n --arg holder "$cluster_operation_lock_holder" '{
    metadata:{labels:{"app.kubernetes.io/part-of":"recipe-db"}},
    spec:{holderIdentity:$holder}
  }'
}

kube() {
  printf '%s\n' "$*" >> "$MOCK_KUBE_CALLS"
  if [[ $1 == create ]]; then
    jq -e --arg node "$storage_node" --arg uuid "$storage_root_uuid" --arg root "$storage_data_root" '
      .spec.nodeName == $node
      and .spec.automountServiceAccountToken == false
      and .spec.containers[0].securityContext.privileged == true
      and .spec.containers[0].securityContext.readOnlyRootFilesystem == true
      and .spec.containers[0].volumeMounts[0].readOnly == true
      and .spec.volumes[0].hostPath.path == "/"
      and (.spec.containers[0].command | join(" ") | contains("/usr/local/sbin/recipe-db-storage-guard"))
      and any(.spec.containers[0].env[]; .name == "EXPECTED_ROOT_UUID" and .value == $uuid)
      and any(.spec.containers[0].env[]; .name == "DATA_ROOT" and .value == $root)
    ' "$3" > /dev/null
  fi
}

released_pv() {
  local node=${1:-recipe-db-pi} path=${2:-/srv/recipe-db/storage/pvc-12345678-1234-1234-1234-123456789abc_recipe-db_recipes}
  jq -nc --arg node "$node" --arg path "$path" '{
    apiVersion:"v1",kind:"PersistentVolume",
    metadata:{name:"pvc-recipes",resourceVersion:"42"},
    spec:{
      storageClassName:"local-path",persistentVolumeReclaimPolicy:"Retain",
      accessModes:["ReadWriteOnce"],volumeMode:"Filesystem",
      capacity:{storage:"1Gi"},local:{path:$path},
      claimRef:{apiVersion:"v1",kind:"PersistentVolumeClaim",namespace:"recipe-db",name:"recipes",uid:"old-claim"},
      nodeAffinity:{required:{nodeSelectorTerms:[{matchExpressions:[
        {key:"kubernetes.io/hostname",operator:"In",values:[$node]}
      ]}]}}
    },
    status:{phase:"Released"}
  }'
}

prepare_reattach_state() {
  printf '{"items":[]}\n' > "$work/persistent-volume-claims.json"
  jq -n --argjson pv "$(released_pv "${1:-recipe-db-pi}" "${2:-/srv/recipe-db/storage/pvc-12345678-1234-1234-1234-123456789abc_recipe-db_recipes}")" \
    '{items:[$pv]}' > "$work/persistent-volumes.json"
}

@test "Pi storage config rejects absent or malformed UUID and mismatched node or root" {
  storage_root_uuid=
  run production_storage_require_config
  [ "$status" -ne 0 ]
  [[ "$output" == *"verified USB root filesystem UUID"* ]]

  storage_root_uuid=not-a-uuid
  run production_storage_require_config
  [ "$status" -ne 0 ]

  storage_root_uuid=02f61d5e-92cb-4f9c-a781-099d97795020
  storage_node=
  run production_storage_require_config
  [ "$status" -ne 0 ]

  storage_node=recipe-db-pi
  storage_data_root=/srv/recipe-db/child
  run production_storage_require_config
  [ "$status" -ne 0 ]
}

@test "Pi lifecycle config requires a verified UUID while render and status can omit it" {
  local valid="$work/valid-pi.yaml" placeholder="$work/placeholder-pi.yaml" no_storage="$work/no-storage.yaml"
  mise exec -- yq '
    .runtime.googleOAuthClientId = "test.apps.googleusercontent.com" |
    .piStorage.expectedRootUuid = "02f61d5e-92cb-4f9c-a781-099d97795020"
  ' "$ROOT/deploy/pi.yaml" > "$valid"
  run production_config "$valid" deploy
  [ "$status" -eq 0 ]

  mise exec -- yq '.piStorage.expectedRootUuid = "REPLACE-WITH-VERIFIED-ROOT-UUID"' \
    "$valid" > "$placeholder"
  run production_config "$placeholder" deploy
  [ "$status" -ne 0 ]
  run production_config "$placeholder" render
  [ "$status" -eq 0 ]
  run production_config "$placeholder" status
  [ "$status" -eq 0 ]

  mise exec -- yq 'del(.piStorage)' "$valid" > "$no_storage"
  run production_config "$no_storage" render
  [ "$status" -eq 0 ]
  run production_config "$no_storage" status
  [ "$status" -eq 0 ]
}

@test "only matching local PVs on the configured Pi root pass identity validation" {
  local pv
  pv=$(released_pv)
  run production_storage_pv_identity_valid "$pv" recipes
  [ "$status" -eq 0 ]
  pv=$(released_pv | jq '.spec.hostPath={path:.spec.local.path,type:"DirectoryOrCreate"} | del(.spec.local)')
  run production_storage_pv_identity_valid "$pv" recipes
  [ "$status" -eq 0 ]

  pv=$(released_pv another-node)
  run production_storage_pv_identity_valid "$pv" recipes
  [ "$status" -ne 0 ]

  pv=$(released_pv recipe-db-pi /srv/other-disk/storage/pvc-12345678-1234-1234-1234-123456789abc_recipe-db_recipes)
  run production_storage_pv_identity_valid "$pv" recipes
  [ "$status" -ne 0 ]
}

@test "host inspection is pinned to the validated node and uses the installed guard read-only" {
  run production_storage_inspect_host
  [ "$status" -eq 0 ]
  [[ "$(< "$MOCK_KUBE_CALLS")" == *"create -f"* ]]
  [[ "$(< "$MOCK_KUBE_CALLS")" == *"delete pod recipe-db-storage-inspection"* ]]
}

@test "Released PV reattachment reserves the existing PV for its matching claim without deleting data" {
  prepare_reattach_state
  run production_storage_reattach
  [ "$status" -eq 0 ]
  [[ "$(< "$MOCK_KUBE_CALLS")" == *"patch persistentvolume pvc-recipes --type=json"* ]]
  [[ "$(< "$MOCK_KUBE_CALLS")" == *'"namespace":"recipe-db","name":"recipes"'* ]]
  [[ "$(< "$MOCK_KUBE_CALLS")" != *"delete"* ]]
}

@test "Released PV reattachment refuses wrong node or data path without patching or deleting" {
  prepare_reattach_state another-node
  run production_storage_reattach
  [ "$status" -ne 0 ]
  [[ "$output" == *"incompatible identity"* ]]
  [ ! -s "$MOCK_KUBE_CALLS" ]

  prepare_reattach_state recipe-db-pi /srv/other-disk/storage/pvc-12345678-1234-1234-1234-123456789abc_recipe-db_recipes
  run production_storage_reattach
  [ "$status" -ne 0 ]
  [ ! -s "$MOCK_KUBE_CALLS" ]
}

@test "Released PV reattachment rejects missing UUID and non-Retain policy" {
  storage_root_uuid=
  prepare_reattach_state
  run production_storage_reattach
  [ "$status" -ne 0 ]
  [[ "$output" == *"verified USB root filesystem UUID"* ]]
  [ ! -s "$MOCK_KUBE_CALLS" ]

  storage_root_uuid=02f61d5e-92cb-4f9c-a781-099d97795020
  local pv
  pv=$(released_pv | jq -c '.spec.persistentVolumeReclaimPolicy = "Delete"')
  jq -n --argjson pv "$pv" '{items:[$pv]}' > "$work/persistent-volumes.json"
  printf '{"items":[]}\n' > "$work/persistent-volume-claims.json"
  run production_storage_reattach
  [ "$status" -ne 0 ]
  [[ "$output" == *"not Retain"* ]]
  [ ! -s "$MOCK_KUBE_CALLS" ]
}
