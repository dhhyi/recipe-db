#!/usr/bin/env bats

# Bats isolates test-local environment overrides in separate subshells.
# shellcheck disable=SC2030,SC2031

load test_helper

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  source "$ROOT/.scripts/lib/production-config.sh"
  source "$ROOT/.scripts/lib/production-storage.sh"
  work="$BATS_TEST_TMPDIR/work"
  mkdir -p "$work"
  target=pi
  cluster=recipe-db-pi
  context=recipe-db-pi
  namespace=recipe-db
  storage_class=recipe-db-retained
  storage_node=recipe-db-pi
  storage_root_uuid=02f61d5e-92cb-4f9c-a781-099d97795020
  storage_data_root=/srv/recipe-db
  timeout=30
  cluster_operation_lock_holder=storage-test
  export MOCK_KUBE_CALLS="$BATS_TEST_TMPDIR/kube-calls"
  export MOCK_LOCAL_STORAGE_CLASS="$BATS_TEST_TMPDIR/local-storage-class.json"
  export MOCK_RETAINED_STORAGE_CLASS="$BATS_TEST_TMPDIR/retained-storage-class.json"
  export MOCK_NODES="$BATS_TEST_TMPDIR/nodes.json"
  export MOCK_PVS="$BATS_TEST_TMPDIR/pvs.json"
  export MOCK_PVCS="$BATS_TEST_TMPDIR/pvcs.json"
  : > "$MOCK_KUBE_CALLS"
  jq -n '{
    target:"pi",cluster:"recipe-db-pi",namespace:"recipe-db",storageClass:"recipe-db-retained",
    piStorage:{node:"recipe-db-pi",expectedRootUuid:"02f61d5e-92cb-4f9c-a781-099d97795020",dataRoot:"/srv/recipe-db"},
    volumes:{recipes:"1Gi"},
    infrastructure:{maintenance:"nginx:stable-alpine@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
    resources:{requests:{cpu:"25m",memory:"32Mi"},limits:{memory:"512Mi"}}
  }' > "$work/config.json"
}

setup_preflight_mocks() {
  jq -n '{
    metadata:{name:"local-path"},
    provisioner:"rancher.io/local-path",
    reclaimPolicy:"Delete",
    volumeBindingMode:"WaitForFirstConsumer"
  }' > "$MOCK_LOCAL_STORAGE_CLASS"
  jq -n '{
    items:[{
      metadata:{name:"recipe-db-pi"},
      spec:{providerID:"k3s://recipe-db-pi"},
      status:{
        nodeInfo:{architecture:"arm64"},
        conditions:[{type:"Ready",status:"True"}]
      }
    }]
  }' > "$MOCK_NODES"
  printf '{"items":[]}\n' > "$MOCK_PVS"
  printf '{"items":[]}\n' > "$MOCK_PVCS"
  rm -f "$MOCK_RETAINED_STORAGE_CLASS"
}

cluster_operation_lock_status() {
  jq -n --arg holder "$cluster_operation_lock_holder" '{
    metadata:{labels:{"app.kubernetes.io/part-of":"recipe-db"}},
    spec:{holderIdentity:$holder}
  }'
}

kube() {
  printf '%s\n' "$*" >> "$MOCK_KUBE_CALLS"
  case "$1 $2 $3" in
    "get storageclass local-path")
      [[ -f $MOCK_LOCAL_STORAGE_CLASS ]] && cat "$MOCK_LOCAL_STORAGE_CLASS" || return 1
      ;;
    "get storageclass recipe-db-retained")
      [[ -f $MOCK_RETAINED_STORAGE_CLASS ]] && cat "$MOCK_RETAINED_STORAGE_CLASS" || return 1
      ;;
    "get nodes -o")
      cat "$MOCK_NODES"
      ;;
    "get persistentvolumes -o")
      cat "$MOCK_PVS"
      ;;
    "get namespace recipe-db")
      printf 'namespace/recipe-db\n'
      ;;
    "get persistentvolumeclaims -o")
      cat "$MOCK_PVCS"
      ;;
    "--namespace kube-system create"*)
      jq -e '.metadata.namespace == "kube-system"' "$5" > /dev/null
      jq -e --arg node "$storage_node" --arg uuid "$storage_root_uuid" --arg root "$storage_data_root" '
        .spec.nodeName == $node
        and .spec.automountServiceAccountToken == false
        and .spec.containers[0].securityContext.privileged == true
        and .spec.containers[0].securityContext.readOnlyRootFilesystem == true
        and .spec.containers[0].volumeMounts[0].readOnly == true
        and .spec.volumes[0].hostPath.path == "/"
        and (.spec.containers[0].command | join(" ") | contains("/usr/local/sbin/recipe-db-storage-guard"))
        and (.spec.containers[0].command | join(" ") | contains("findmnt"))
        and any(.spec.containers[0].env[]; .name == "EXPECTED_ROOT_UUID" and .value == $uuid)
        and any(.spec.containers[0].env[]; .name == "DATA_ROOT" and .value == $root)
      ' "$5" > /dev/null
      ;;
    "create -f "*)
      if jq -e '.kind == "StorageClass"' "$3" > /dev/null; then
        cp "$3" "$MOCK_RETAINED_STORAGE_CLASS"
      else
        return 1
      fi
      ;;
    "--namespace kube-system wait"*) ;;
    "--namespace kube-system logs"*)
      printf 'Verified USB-backed ext4 root and runtime storage identity\n'
      ;;
    "--namespace kube-system delete"*) ;;
    "patch storageclass"*)
      return 1
      ;;
    "patch persistentvolume"*)
      jq '(.items[] | select(.metadata.name == "pvc-recipes").spec.persistentVolumeReclaimPolicy) = "Retain"' \
        "$MOCK_PVS" > "$BATS_TEST_TMPDIR/pvs-updated.json"
      cp "$BATS_TEST_TMPDIR/pvs-updated.json" "$MOCK_PVS"
      ;;
    "wait --for=jsonpath="*) ;;

    *) ;;

  esac
}

released_pv() {
  local node=${1:-recipe-db-pi} path=${2:-/srv/recipe-db/storage/pvc-12345678-1234-1234-1234-123456789abc_recipe-db_recipes} class=${3:-local-path}
  jq -nc --arg node "$node" --arg path "$path" --arg class "$class" '{
    apiVersion:"v1",kind:"PersistentVolume",
    metadata:{name:"pvc-recipes",resourceVersion:"42"},
    spec:{
      storageClassName:$class,persistentVolumeReclaimPolicy:"Retain",
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
  jq -n --argjson pv "$(released_pv "${1:-recipe-db-pi}" "${2:-/srv/recipe-db/storage/pvc-12345678-1234-1234-1234-123456789abc_recipe-db_recipes}" "${3:-local-path}")" \
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
    .context = "explicit-pi" |
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
  pv=$(released_pv recipe-db-pi /srv/recipe-db/storage/pvc-12345678-1234-1234-1234-123456789abc_recipe-db_recipes recipe-db-retained)
  run production_storage_pv_identity_valid "$pv" recipes
  [ "$status" -eq 0 ]
  pv=$(released_pv | jq -c '.status.phase = "Available" | del(.spec.claimRef.uid)')
  run production_storage_pv_identity_valid "$pv" recipes
  [ "$status" -eq 0 ]
  pv=$(released_pv | jq -c '.status.phase = "Available" | del(.spec.claimRef.uid) | .spec.claimRef.name = "other"')
  run production_storage_pv_identity_valid "$pv" recipes
  [ "$status" -ne 0 ]
  pv=$(released_pv | jq -c '.status.phase = "Available" | del(.spec.claimRef.uid) | .spec.claimRef.namespace = "other"')
  run production_storage_pv_identity_valid "$pv" recipes
  [ "$status" -ne 0 ]
  pv=$(released_pv | jq -c '.status.phase = "Available" | del(.spec.claimRef.uid) | .spec.persistentVolumeReclaimPolicy = "Delete"')
  run production_storage_pv_identity_valid "$pv" recipes
  [ "$status" -ne 0 ]
  pv=$(released_pv | jq -c '.status.phase = "Available"')
  run production_storage_pv_identity_valid "$pv" recipes
  [ "$status" -ne 0 ]
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
  [[ "$(< "$MOCK_KUBE_CALLS")" == *"--namespace kube-system create -f"* ]]
  [[ "$(< "$MOCK_KUBE_CALLS")" == *"--namespace kube-system wait --for=jsonpath="* ]]
  [[ "$(< "$MOCK_KUBE_CALLS")" == *"--namespace kube-system logs recipe-db-storage-inspection"* ]]
  [[ "$(< "$MOCK_KUBE_CALLS")" == *"--namespace kube-system delete pod recipe-db-storage-inspection"* ]]
}

@test "preflight creates the owned Retain class and never mutates stock local-path" {
  setup_preflight_mocks
  run production_storage_preflight
  [ "$status" -eq 0 ]
  jq -e --arg node "$storage_node" --arg path "$storage_data_root/storage" '
    .metadata.name == "recipe-db-retained"
    and .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
    and .provisioner == "rancher.io/local-path"
    and .parameters.nodePath == $path
    and .reclaimPolicy == "Retain"
    and .volumeBindingMode == "WaitForFirstConsumer"
    and .allowedTopologies == [{matchLabelExpressions:[
      {key:"kubernetes.io/hostname",values:[$node]}
    ]}]
  ' "$MOCK_RETAINED_STORAGE_CLASS"
  jq -e '.reclaimPolicy == "Delete"' "$MOCK_LOCAL_STORAGE_CLASS"
  [[ "$(< "$MOCK_KUBE_CALLS")" != *"patch storageclass"* ]]
  [[ "$(< "$MOCK_KUBE_CALLS")" == *"create -f"* ]]
}

@test "preflight verifies an existing compatible Retain class without replacing it" {
  setup_preflight_mocks
  production_storage_retained_class_manifest
  cp "$work/retained-storage-class.json" "$MOCK_RETAINED_STORAGE_CLASS"
  run production_storage_preflight
  [ "$status" -eq 0 ]
  [[ "$(< "$MOCK_KUBE_CALLS")" != *"$work/retained-storage-class.json"* ]]
  [[ "$(< "$MOCK_KUBE_CALLS")" != *"patch storageclass"* ]]
  jq -e '.reclaimPolicy == "Delete"' "$MOCK_LOCAL_STORAGE_CLASS"
}

@test "preflight refuses an incompatible retained class without patching either class" {
  setup_preflight_mocks
  jq -n '{
    metadata:{name:"recipe-db-retained",labels:{"app.kubernetes.io/part-of":"recipe-db"}},
    provisioner:"rancher.io/local-path",
    parameters:{nodePath:"/var/lib/rancher/k3s/storage"},
    reclaimPolicy:"Delete",volumeBindingMode:"Immediate"
  }' > "$MOCK_RETAINED_STORAGE_CLASS"
  run production_storage_preflight
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing modification"* ]]
  [[ "$(< "$MOCK_KUBE_CALLS")" != *"patch storageclass"* ]]
  jq -e '.reclaimPolicy == "Delete"' "$MOCK_LOCAL_STORAGE_CLASS"
}

@test "preflight retains existing local-path PVs without changing either StorageClass" {
  setup_preflight_mocks
  local pv
  pv=$(released_pv recipe-db-pi /srv/recipe-db/storage/pvc-12345678-1234-1234-1234-123456789abc_recipe-db_recipes local-path \
    | jq -c '.status.phase = "Bound" | .spec.persistentVolumeReclaimPolicy = "Delete"')
  jq -n --argjson pv "$pv" '{items:[$pv]}' > "$MOCK_PVS"
  jq -n '{
    items:[{
      metadata:{name:"recipes",uid:"old-claim"},
      spec:{storageClassName:"local-path",accessModes:["ReadWriteOnce"],
        resources:{requests:{storage:"1Gi"}},volumeName:"pvc-recipes"},
      status:{phase:"Bound"}
    }]
  }' > "$MOCK_PVCS"
  run production_storage_preflight
  [ "$status" -eq 0 ]
  jq -e '.items[0].spec.persistentVolumeReclaimPolicy == "Retain"
    and .items[0].spec.storageClassName == "local-path"' "$MOCK_PVS"
  jq -e '.reclaimPolicy == "Delete"' "$MOCK_LOCAL_STORAGE_CLASS"
  [[ "$(< "$MOCK_KUBE_CALLS")" == *"patch persistentvolume pvc-recipes"* ]]
  [[ "$(< "$MOCK_KUBE_CALLS")" != *"patch storageclass"* ]]
}

@test "prepare_claims preserves bound classes and explicitly reattached PVs without risking fresh data" {
  local manifest="$BATS_TEST_TMPDIR/rendered.yml" pv
  printf '%s\n' \
    'apiVersion: v1' 'kind: PersistentVolumeClaim' 'metadata:' '  name: recipes' \
    'spec:' '  accessModes: [ReadWriteOnce]' '  storageClassName: recipe-db-retained' > "$manifest"
  pv=$(released_pv recipe-db-pi /srv/recipe-db/storage/pvc-12345678-1234-1234-1234-123456789abc_recipe-db_recipes local-path \
    | jq -c '.status.phase = "Bound"')
  jq -n --argjson pv "$pv" '{items:[$pv]}' > "$work/persistent-volumes.json"
  jq -n '{
    items:[{
      metadata:{name:"recipes",uid:"old-claim"},
      spec:{storageClassName:"local-path",accessModes:["ReadWriteOnce"],
        resources:{requests:{storage:"1Gi"}},volumeName:"pvc-recipes"},
      status:{phase:"Bound"}
    }]
  }' > "$work/persistent-volume-claims.json"
  production_storage_prepare_claims "$manifest"
  [ "$(yq -r '.spec.storageClassName' "$manifest")" = local-path ]

  printf '%s\n' \
    'apiVersion: v1' 'kind: PersistentVolumeClaim' 'metadata:' '  name: recipes' \
    'spec:' '  accessModes: [ReadWriteOnce]' '  storageClassName: recipe-db-retained' > "$manifest"
  pv=$(released_pv recipe-db-pi /srv/recipe-db/storage/pvc-12345678-1234-1234-1234-123456789abc_recipe-db_recipes recipe-db-retained)
  jq -n --argjson pv "$pv" '{items:[$pv]}' > "$work/persistent-volumes.json"
  printf '{"items":[]}\n' > "$work/persistent-volume-claims.json"
  run production_storage_prepare_claims "$manifest"
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be explicitly reattached"* ]]

  printf '%s\n' \
    'apiVersion: v1' 'kind: PersistentVolumeClaim' 'metadata:' '  name: recipes' \
    'spec:' '  accessModes: [ReadWriteOnce]' '  storageClassName: recipe-db-retained' > "$manifest"
  prepare_reattach_state recipe-db-pi \
    /srv/recipe-db/storage/pvc-12345678-1234-1234-1234-123456789abc_recipe-db_recipes \
    recipe-db-retained
  run production_storage_reattach
  [ "$status" -eq 0 ]
  production_storage_prepare_claims "$manifest"
  [ "$(yq -r '.spec.storageClassName' "$manifest")" = recipe-db-retained ]
  [ "$(yq -r '.spec.volumeName' "$manifest")" = pvc-recipes ]

  printf '%s\n' \
    'apiVersion: v1' 'kind: PersistentVolumeClaim' 'metadata:' '  name: recipes' \
    'spec:' '  accessModes: [ReadWriteOnce]' '  storageClassName: recipe-db-retained' > "$manifest"
  printf '{"items":[]}\n' > "$work/persistent-volumes.json"
  production_storage_prepare_claims "$manifest"
  [ "$(yq -r '.spec.storageClassName' "$manifest")" = recipe-db-retained ]
}

@test "Released PV reattachment reserves the existing PV for its matching claim without deleting data" {
  prepare_reattach_state
  run production_storage_reattach
  [ "$status" -eq 0 ]
  [[ "$(< "$MOCK_KUBE_CALLS")" == *"patch persistentvolume pvc-recipes --type=json"* ]]
  [[ "$(< "$MOCK_KUBE_CALLS")" == *'"namespace":"recipe-db","name":"recipes"'* ]]
  [[ "$(< "$MOCK_KUBE_CALLS")" != *"delete"* ]]
}

@test "Released retained PV reattachment keeps its dedicated StorageClass" {
  prepare_reattach_state recipe-db-pi \
    /srv/recipe-db/storage/pvc-12345678-1234-1234-1234-123456789abc_recipe-db_recipes \
    recipe-db-retained
  run production_storage_reattach
  [ "$status" -eq 0 ]
  [[ "$(< "$MOCK_KUBE_CALLS")" == *"patch persistentvolume pvc-recipes --type=json"* ]]
  [[ "$(< "$MOCK_KUBE_CALLS")" != *"storageClassName"* ]]
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
