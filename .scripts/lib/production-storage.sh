#!/usr/bin/env bash
# Shared storage safeguards for production operations.
# shellcheck disable=SC2154

production_storage_require_config() {
  [[ ${target:-} == pi ]] || production_fail "Pi storage operations require target pi"
  [[ ${storage_class:-} == local-path ]] || production_fail "Pi storage requires the local-path storage class"
  [[ -n ${context:-} && ${storage_node:-} =~ ^[a-z][a-z0-9-]{0,61}[a-z0-9]$ ]] \
    || production_fail "Pi context and storage node must be explicit"
  [[ $storage_root_uuid =~ ^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$ ]] \
    || production_fail "Pi storage requires the verified USB root filesystem UUID"
  [[ $storage_data_root =~ ^/srv/[a-zA-Z0-9_-]+$ ]] \
    || production_fail "Pi storage data root must be one direct directory beneath /srv"
}

production_storage_require_lock() {
  local lease
  [[ -n ${cluster_operation_lock_holder:-} ]] \
    || production_fail "Pi storage operations require the shared cluster operation lock"
  declare -F cluster_operation_lock_status > /dev/null \
    || production_fail "shared cluster operation lock support is unavailable"
  lease=$(cluster_operation_lock_status) \
    || production_fail "could not verify the shared cluster operation lock"
  jq -e --arg holder "$cluster_operation_lock_holder" '
    .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
    and .spec.holderIdentity == $holder
  ' <<< "$lease" > /dev/null \
    || production_fail "shared cluster operation lock ownership changed"
}

production_storage_pv_identity_valid() {
  local pv=$1 claim=$2
  jq -e --arg namespace "$namespace" --arg claim "$claim" \
    --arg node "$storage_node" --arg root "$storage_data_root" \
    --arg storage_class "$storage_class" '
    .kind == "PersistentVolume"
    and .spec.storageClassName == $storage_class
    and .spec.accessModes == ["ReadWriteOnce"]
    and (.spec.volumeMode // "Filesystem") == "Filesystem"
    and .spec.claimRef.namespace == $namespace
    and .spec.claimRef.name == $claim
    and (.status.phase == "Bound" or .status.phase == "Released")
    and ((.spec.local.path // .spec.hostPath.path) |
      test("^" + $root + "/storage/pvc-[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}_" +
        $namespace + "_" + $claim + "$"))
    and any(.spec.nodeAffinity.required.nodeSelectorTerms[]?;
      any(.matchExpressions[]?;
        .key == "kubernetes.io/hostname" and .operator == "In" and
        .values == [$node]))
  ' <<< "$pv" > /dev/null
}

production_storage_require_pv_capacity() {
  local pv=$1 claim=$2
  jq -e --arg claim "$claim" --arg request "$(jq -r --arg name "$claim" \
    '.volumes[$name]' "$work/config.json")" '
    def bytes:
      if test("^[1-9][0-9]*Mi$") then (sub("Mi$"; "") | tonumber) * 1048576
      elif test("^[1-9][0-9]*Gi$") then (sub("Gi$"; "") | tonumber) * 1073741824
      else -1 end;
    .spec.capacity.storage as $capacity |
    ($capacity | bytes) >= ($request | bytes)
  ' <<< "$pv" > /dev/null
}

production_storage_validate_existing_claim() {
  local claim=$1 pvc=$2 volume_name request
  request=$(jq -r --arg name "$claim" '.volumes[$name]' "$work/config.json")
  jq -e --arg claim "$claim" --arg storage_class "$storage_class" \
    --arg request "$request" '
    def bytes:
      if test("^[1-9][0-9]*Mi$") then (sub("Mi$"; "") | tonumber) * 1048576
      elif test("^[1-9][0-9]*Gi$") then (sub("Gi$"; "") | tonumber) * 1073741824
      else -1 end;
    .metadata.name == $claim
    and .spec.storageClassName == $storage_class
    and .spec.accessModes == ["ReadWriteOnce"]
    and (.spec.volumeMode // "Filesystem") == "Filesystem"
    and (.spec.resources.requests.storage | bytes) >= ($request | bytes)
    and .status.phase == "Bound"
    and (.spec.volumeName | type == "string" and length > 0)
  ' <<< "$pvc" > /dev/null || return 1
  volume_name=$(jq -r .spec.volumeName <<< "$pvc")
  jq -e --arg name "$volume_name" '.items[] | select(.metadata.name == $name)' \
    "$work/persistent-volumes.json" > "$work/claim-volume.json" \
    || return 1
  jq -e --arg uid "$(jq -r .metadata.uid <<< "$pvc")" \
    '.spec.claimRef.uid == $uid' "$work/claim-volume.json" > /dev/null \
    || return 1
  if ! production_storage_pv_identity_valid "$(< "$work/claim-volume.json")" "$claim"; then
    return 1
  fi
  production_storage_require_pv_capacity "$(< "$work/claim-volume.json")" "$claim"
}

production_storage_retain_existing_volumes() {
  local name pv
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    pv=$(jq -c --arg namespace "$namespace" --arg name "$name" '
      .items[] | select(.spec.claimRef.namespace == $namespace and .spec.claimRef.name == $name)
    ' "$work/persistent-volumes.json")
    [[ -n $pv ]] || continue
    if ! production_storage_pv_identity_valid "$pv" "$name" \
      || ! production_storage_require_pv_capacity "$pv" "$name"; then
      production_fail "incompatible local-path PV for $namespace/$name; refusing to adopt or modify it"
    fi
    if [[ $(jq -r .spec.persistentVolumeReclaimPolicy <<< "$pv") != Retain ]]; then
      kube patch persistentvolume "$(jq -r .metadata.name <<< "$pv")" \
        --type=merge -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}' > /dev/null \
        || production_fail "could not preserve existing PV $(jq -r .metadata.name <<< "$pv")"
    fi
  done < <(jq -r '.volumes | keys[]' "$work/config.json")
}

production_storage_inspect_existing_volumes() {
  local name pv candidates count
  kube get persistentvolumes -o json > "$work/persistent-volumes.json" \
    || production_fail "could not inspect existing persistent volumes"
  : > "$work/storage-paths.txt"
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    candidates=$(jq -c --arg namespace "$namespace" --arg name "$name" '
      [.items[] | select(.spec.claimRef.namespace == $namespace and .spec.claimRef.name == $name)]
    ' "$work/persistent-volumes.json")
    count=$(jq length <<< "$candidates")
    ((count <= 1)) \
      || production_fail "multiple PVs match $namespace/$name; refusing ambiguous storage"
    ((count == 1)) || continue
    pv=$(jq -c '.[0]' <<< "$candidates")
    if ! production_storage_pv_identity_valid "$pv" "$name" \
      || ! production_storage_require_pv_capacity "$pv" "$name"; then
      production_fail "incompatible local-path PV for $namespace/$name; refusing to adopt or modify it"
    fi
    jq -r '.spec.local.path // .spec.hostPath.path' <<< "$pv" >> "$work/storage-paths.txt"
  done < <(jq -r '.volumes | keys[]' "$work/config.json")
}

production_storage_check_existing_claims() {
  local name pvc
  kube get namespace "$namespace" --ignore-not-found -o name > "$work/namespace.txt" \
    || production_fail "could not inspect the application namespace"
  if [[ ! -s $work/namespace.txt ]]; then
    printf '{"items":[]}\n' > "$work/persistent-volume-claims.json"
    return 0
  fi
  kube get persistentvolumeclaims -o json > "$work/persistent-volume-claims.json" \
    || production_fail "could not inspect existing application PVCs"
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    pvc=$(jq -c --arg name "$name" '.items[] | select(.metadata.name == $name)' \
      "$work/persistent-volume-claims.json")
    [[ -n $pvc ]] || continue
    production_storage_validate_existing_claim "$name" "$pvc" \
      || production_fail "incompatible or unbound PVC $namespace/$name; refusing to adopt local-path data"
  done < <(jq -r '.volumes | keys[]' "$work/config.json")
}

production_storage_inspect_host() {
  local pod=recipe-db-storage-inspection paths='' path
  while IFS= read -r path; do
    [[ -n $path ]] && paths+="$path "
  done < "${work}/storage-paths.txt"
  jq -n --arg name "$pod" --arg namespace kube-system \
    --arg node "$storage_node" --arg image "$(jq -r '.infrastructure.maintenance' "$work/config.json")" \
    --arg uuid "$storage_root_uuid" --arg root "$storage_data_root" --arg paths "${paths:-}" \
    --argjson resources "$(jq -c .resources "$work/config.json")" \
    --argjson deadline "$timeout" '
    {
      apiVersion: "v1", kind: "Pod",
      metadata: {name: $name, namespace: $namespace, labels: {"app.kubernetes.io/part-of":"recipe-db"}},
      spec: {
        nodeName: $node,
        restartPolicy: "Never",
        activeDeadlineSeconds: $deadline,
        automountServiceAccountToken: false,
        containers: [{
          name: "inspect-storage", image: $image, imagePullPolicy: "IfNotPresent",
          command: ["/bin/sh", "-ec",
            "for path in $PVC_PATHS; do test -d \"/host$path\" && test ! -L \"/host$path\" && test \"$(readlink -f \"/host$path\")\" = \"/host$path\" || exit 1; done; chroot /host /usr/local/sbin/recipe-db-storage-guard \"$EXPECTED_ROOT_UUID\" \"$DATA_ROOT\""],
          env: [
            {name: "EXPECTED_ROOT_UUID", value: $uuid},
            {name: "DATA_ROOT", value: $root},
            {name: "PVC_PATHS", value: $paths}
          ],
          resources: $resources,
          securityContext: {privileged: true,readOnlyRootFilesystem: true},
          volumeMounts: [{name:"host-root", mountPath:"/host", readOnly:true}]
        }],
        volumes: [{name:"host-root", hostPath:{path:"/",type:"Directory"}}]
      }
    }' > "$work/storage-inspection-pod.json"
  kube create -f "$work/storage-inspection-pod.json" > /dev/null \
    || production_fail "could not create private Pi storage inspection Pod; inspect any existing inspection Pod before retrying"
  if ! kube wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$pod" \
    --timeout="${timeout}s" > /dev/null; then
    kube logs "$pod" >&2 || true
    kube delete pod "$pod" --wait=true > /dev/null 2>&1 || true
    production_fail "Pi host storage guard failed or timed out; deployment refused"
  fi
  if ! kube logs "$pod" > /dev/null; then
    kube delete pod "$pod" --wait=true > /dev/null 2>&1 || true
    production_fail "could not verify Pi host storage guard output"
  fi
  kube delete pod "$pod" --wait=true > /dev/null \
    || production_fail "could not remove the completed private storage inspection Pod"
}

production_storage_preflight() {
  production_storage_require_config
  production_storage_require_lock
  kube get nodes -o json > "$work/pi-node.json" \
    || production_fail "configured Pi node $storage_node is unavailable"
  jq -e --arg node "$storage_node" '
    (.items | length) == 1 and .items[0].metadata.name == $node and
    .items[0].spec.providerID == ("k3s://" + $node) and
    .items[0].status.nodeInfo.architecture == "arm64" and
    any(.items[0].status.conditions[]; .type == "Ready" and .status == "True")
  ' "$work/pi-node.json" > /dev/null \
    || production_fail "configured Pi node is not Ready or its identity does not match"
  kube get storageclass "$storage_class" -o json > "$work/storage-class.json" \
    || production_fail "required local-path StorageClass is missing"
  jq -e '.provisioner == "rancher.io/local-path"' "$work/storage-class.json" > /dev/null \
    || production_fail "local-path StorageClass uses an incompatible provisioner"
  production_storage_inspect_existing_volumes
  production_storage_inspect_host
  production_storage_check_existing_claims
  production_storage_retain_existing_volumes
  if [[ $(jq -r .reclaimPolicy "$work/storage-class.json") != Retain ]]; then
    kube patch storageclass "$storage_class" --type=merge \
      -p '{"reclaimPolicy":"Retain"}' > /dev/null \
      || production_fail "could not set local-path reclaim policy to Retain"
  fi
}

production_storage_reattach() {
  local name candidates count pv pv_name old_resource_version patch
  production_storage_require_config
  production_storage_require_lock
  [[ -f $work/config.json ]] || production_fail "production configuration is unavailable"
  [[ -f $work/persistent-volume-claims.json ]] \
    || production_fail "run Pi storage preflight before Released-PV reattachment"
  [[ -f $work/persistent-volumes.json ]] \
    || production_fail "run Pi storage preflight before Released-PV reattachment"
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    if jq -e --arg name "$name" 'any(.items[]; .metadata.name == $name)' \
      "$work/persistent-volume-claims.json" > /dev/null; then
      continue
    fi
    candidates=$(jq -c --arg namespace "$namespace" --arg name "$name" '
      [.items[] | select(.status.phase == "Released" and
        .spec.claimRef.namespace == $namespace and .spec.claimRef.name == $name)]
    ' "$work/persistent-volumes.json")
    count=$(jq length <<< "$candidates")
    ((count <= 1)) \
      || production_fail "multiple Released PVs match $namespace/$name; refusing ambiguous reattachment"
    ((count == 1)) || continue
    pv=$(jq -c '.[0]' <<< "$candidates")
    jq -e '.spec.persistentVolumeReclaimPolicy == "Retain"' <<< "$pv" > /dev/null \
      || production_fail "Released PV for $namespace/$name is not Retain; refusing reattachment"
    if ! production_storage_pv_identity_valid "$pv" "$name" \
      || ! production_storage_require_pv_capacity "$pv" "$name"; then
      production_fail "Released PV for $namespace/$name has incompatible identity; data was left untouched"
    fi
    pv_name=$(jq -r .metadata.name <<< "$pv")
    old_resource_version=$(jq -r .metadata.resourceVersion <<< "$pv")
    patch=$(jq -cn --arg version "$old_resource_version" --arg namespace "$namespace" --arg name "$name" '
      [
        {op:"test",path:"/metadata/resourceVersion",value:$version},
        {op:"test",path:"/spec/claimRef/namespace",value:$namespace},
        {op:"test",path:"/spec/claimRef/name",value:$name},
        {op:"replace",path:"/spec/claimRef",value:{
          apiVersion:"v1",kind:"PersistentVolumeClaim",namespace:$namespace,name:$name
        }}
      ]')
    kube patch persistentvolume "$pv_name" --type=json -p "$patch" > /dev/null \
      || production_fail "atomic reattachment of Released PV $pv_name failed; no PV or data was deleted"
  done < <(jq -r '.volumes | keys[]' "$work/config.json")
}
