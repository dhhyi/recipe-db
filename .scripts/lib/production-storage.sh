#!/usr/bin/env bash
# Shared storage safeguards for production operations.
# shellcheck disable=SC2154

production_storage_require_config() {
  [[ ${target:-} == pi ]] || production_fail "Pi storage operations require target pi"
  [[ ${storage_class:-} == recipe-db-retained ]] \
    || production_fail "Pi storage requires the recipe-db-retained StorageClass for new claims"
  [[ -n ${context:-} && ${storage_node:-} == "$cluster" &&
    $storage_node =~ ^[a-z][a-z0-9-]{0,61}[a-z0-9]$ ]] \
    || production_fail "Pi context must be explicit and storage node must match the configured cluster"
  [[ $storage_root_uuid =~ ^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$ ]] \
    || production_fail "Pi storage requires the verified USB root filesystem UUID"
  [[ $storage_data_root =~ ^/srv/[a-zA-Z0-9_-]+$ ]] \
    || production_fail "Pi storage data root must be one direct directory beneath /srv"
}

production_storage_class_supported() {
  [[ $1 == local-path || $1 == "$storage_class" ]]
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
    and (.spec.storageClassName == $storage_class or .spec.storageClassName == "local-path")
    and .spec.accessModes == ["ReadWriteOnce"]
    and (.spec.volumeMode // "Filesystem") == "Filesystem"
    and .spec.claimRef.namespace == $namespace
    and .spec.claimRef.name == $claim
    and (
      .status.phase == "Bound" or .status.phase == "Released" or
      (.status.phase == "Available"
        and .spec.persistentVolumeReclaimPolicy == "Retain"
        and (.spec.claimRef.uid // "") == "")
    )
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
    and (.spec.storageClassName == $storage_class or .spec.storageClassName == "local-path")
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
  jq -e --arg class "$(jq -r .spec.storageClassName <<< "$pvc")" \
    '.spec.storageClassName == $class' "$work/claim-volume.json" > /dev/null \
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
  local name pv modified=false
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
      modified=true
    fi
  done < <(jq -r '.volumes | keys[]' "$work/config.json")
  if $modified; then
    kube get persistentvolumes -o json > "$work/persistent-volumes.json" \
      || production_fail "could not verify Retain policy updates on existing PVs"
  fi
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
            "for path in $PVC_PATHS; do case \"$path\" in \"$DATA_ROOT\"/storage/pvc-*) ;; *) echo \"unexpected PV path: $path\" >&2; exit 1 ;; esac; test -d \"/host$path\" && test ! -L \"/host$path\" && test \"$(readlink -f \"/host$path\")\" = \"/host$path\" || exit 1; identity=$(chroot /host /usr/bin/findmnt --noheadings --output UUID,FSTYPE --target \"$path\"); set -- $identity; test \"$#\" -eq 2 && test \"$(printf '%s' \"$1\" | tr A-F a-f)\" = \"$EXPECTED_ROOT_UUID\" && test \"$2\" = ext4 || exit 1; done; chroot /host /usr/local/sbin/recipe-db-storage-guard \"$EXPECTED_ROOT_UUID\" \"$DATA_ROOT\""],
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
  kube --namespace kube-system create -f "$work/storage-inspection-pod.json" > /dev/null \
    || production_fail "could not create private Pi storage inspection Pod; inspect any existing inspection Pod before retrying"
  if ! kube --namespace kube-system wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$pod" \
    --timeout="${timeout}s" > /dev/null; then
    kube --namespace kube-system logs "$pod" >&2 || true
    kube --namespace kube-system delete pod "$pod" --wait=true > /dev/null 2>&1 || true
    production_fail "Pi host storage guard failed or timed out; deployment refused"
  fi
  if ! kube --namespace kube-system logs "$pod" > /dev/null; then
    kube --namespace kube-system delete pod "$pod" --wait=true > /dev/null 2>&1 || true
    production_fail "could not verify Pi host storage guard output"
  fi
  kube --namespace kube-system delete pod "$pod" --wait=true > /dev/null \
    || production_fail "could not remove the completed private storage inspection Pod"
}

production_storage_retained_class_manifest() {
  jq -n --arg name "$storage_class" --arg node "$storage_node" \
    --arg path "$storage_data_root/storage" '{
    apiVersion:"storage.k8s.io/v1",kind:"StorageClass",
    metadata:{name:$name,labels:{"app.kubernetes.io/part-of":"recipe-db"}},
    provisioner:"rancher.io/local-path",
    parameters:{nodePath:$path},
    reclaimPolicy:"Retain",
    volumeBindingMode:"WaitForFirstConsumer",
    allowedTopologies:[{matchLabelExpressions:[
      {key:"kubernetes.io/hostname",values:[$node]}
    ]}]
  }' > "$work/retained-storage-class.json"
}

production_storage_ensure_retained_class() {
  production_storage_retained_class_manifest
  if ! kube get storageclass "$storage_class" -o json \
    > "$work/retained-storage-class-live.json" 2> /dev/null; then
    kube create -f "$work/retained-storage-class.json" > /dev/null \
      || production_fail "could not create $storage_class StorageClass; refusing to mutate stock local-path"
    kube get storageclass "$storage_class" -o json > "$work/retained-storage-class-live.json" \
      || production_fail "created $storage_class StorageClass could not be verified"
  fi
  jq -e --arg name "$storage_class" --arg node "$storage_node" \
    --arg path "$storage_data_root/storage" '
    .metadata.name == $name
    and .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
    and .provisioner == "rancher.io/local-path"
    and .parameters.nodePath == $path
    and .reclaimPolicy == "Retain"
    and .volumeBindingMode == "WaitForFirstConsumer"
    and .allowedTopologies == [{matchLabelExpressions:[
      {key:"kubernetes.io/hostname",values:[$node]}
    ]}]
  ' "$work/retained-storage-class-live.json" > /dev/null \
    || production_fail "$storage_class StorageClass is not the owned, node-pinned Retain class; refusing modification"
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
  kube get storageclass local-path -o json > "$work/stock-storage-class.json" \
    || production_fail "required local-path StorageClass is missing"
  jq -e '.metadata.name == "local-path" and .provisioner == "rancher.io/local-path"' \
    "$work/stock-storage-class.json" > /dev/null \
    || production_fail "local-path StorageClass uses an incompatible provisioner"
  production_storage_ensure_retained_class
  production_storage_inspect_existing_volumes
  production_storage_inspect_host
  production_storage_check_existing_claims
  production_storage_retain_existing_volumes
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
    jq --arg pv "$pv_name" --arg namespace "$namespace" --arg name "$name" '
      (.items[] | select(.metadata.name == $pv) | .spec.claimRef) = {
        apiVersion:"v1",kind:"PersistentVolumeClaim",namespace:$namespace,name:$name
      }
    ' "$work/persistent-volumes.json" > "$work/persistent-volumes-reattached.json" \
      || production_fail "could not record explicit reattachment of PV $pv_name"
    mv "$work/persistent-volumes-reattached.json" "$work/persistent-volumes.json" \
      || production_fail "could not record explicit reattachment of PV $pv_name"
  done < <(jq -r '.volumes | keys[]' "$work/config.json")
}

production_storage_prepare_claims() {
  local rendered=$1 name pvc pv candidates count volume_name class classes volume_names
  production_storage_require_config
  [[ -f $rendered && -f $work/persistent-volume-claims.json &&
    -f $work/persistent-volumes.json ]] \
    || production_fail "Pi storage preflight must run before preparing rendered PVCs"
  classes='{}'
  volume_names='{}'
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    pvc=$(jq -c --arg name "$name" '.items[] | select(.metadata.name == $name)' \
      "$work/persistent-volume-claims.json")
    if [[ -n $pvc ]]; then
      production_storage_validate_existing_claim "$name" "$pvc" \
        || production_fail "cannot preserve storage class for incompatible PVC $namespace/$name"
      class=$(jq -r .spec.storageClassName <<< "$pvc")
    else
      candidates=$(jq -c --arg namespace "$namespace" --arg name "$name" '
        [.items[] | select(
          (.status.phase == "Released" or .status.phase == "Available")
          and .spec.claimRef.namespace == $namespace
          and .spec.claimRef.name == $name
        )]
      ' "$work/persistent-volumes.json")
      count=$(jq length <<< "$candidates")
      ((count <= 1)) \
        || production_fail "multiple retained PVs match $namespace/$name; refusing ambiguous PVC class"
      if ((count == 1)); then
        pv=$(jq -c '.[0]' <<< "$candidates")
        if jq -e '.status.phase == "Released" and (.spec.claimRef.uid // "") != ""' \
          <<< "$pv" > /dev/null; then
          production_fail "Released PV for $namespace/$name must be explicitly reattached before creating its PVC"
        fi
        jq -e '.spec.persistentVolumeReclaimPolicy == "Retain"' <<< "$pv" > /dev/null \
          || production_fail "reserved PV for $namespace/$name is not Retain"
        if ! production_storage_pv_identity_valid "$pv" "$name" \
          || ! production_storage_require_pv_capacity "$pv" "$name"; then
          production_fail "reserved PV for $namespace/$name has incompatible identity; refusing to alter rendered PVC"
        fi
        class=$(jq -r .spec.storageClassName <<< "$pv")
        volume_name=$(jq -r .metadata.name <<< "$pv")
        volume_names=$(jq -c --arg name "$name" --arg volume "$volume_name" \
          '. + {($name):$volume}' <<< "$volume_names")
      else
        class=$storage_class
      fi
    fi
    production_storage_class_supported "$class" \
      || production_fail "unsupported storage class for $namespace/$name"
    classes=$(jq -c --arg name "$name" --arg class "$class" \
      '. + {($name):$class}' <<< "$classes")
  done < <(jq -r '.volumes | keys[]' "$work/config.json")

  STORAGE_CLASS_OVERRIDES=$classes STORAGE_VOLUME_OVERRIDES=$volume_names yq -i '
    if .kind == "PersistentVolumeClaim" and
      (env(STORAGE_CLASS_OVERRIDES)[.metadata.name] != null)
    then .spec.storageClassName = env(STORAGE_CLASS_OVERRIDES)[.metadata.name]
    else . end |
    if .kind == "PersistentVolumeClaim" and
      (env(STORAGE_VOLUME_OVERRIDES)[.metadata.name] != null)
    then .spec.volumeName = env(STORAGE_VOLUME_OVERRIDES)[.metadata.name]
    else . end
  ' "$rendered" || production_fail "could not prepare rendered Pi PVC storage classes"

  while IFS= read -r name; do
    [[ -n $name ]] || continue
    class=$(jq -r --arg name "$name" '.[$name]' <<< "$classes")
    local -a rendered_classes=()
    mapfile -t rendered_classes < <(yq -r \
      "select(.kind == \"PersistentVolumeClaim\" and .metadata.name == \"$name\") | .spec.storageClassName" \
      "$rendered")
    ((${#rendered_classes[@]} == 1)) && [[ ${rendered_classes[0]} == "$class" ]] \
      || production_fail "rendered manifest must contain exactly one verified PVC for $namespace/$name"
  done < <(jq -r '.volumes | keys[]' "$work/config.json")
}
