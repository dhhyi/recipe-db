# Test-local environment overrides are intentional; MOCK_LOG comes from test_helper.
# shellcheck disable=SC2030,SC2031,SC2153

load test_helper

setup() {
  setup_fixture production-k3d.sh
  export FIXTURE_ROOT
  export MISE_TRUSTED_CONFIG_PATHS="$FIXTURE_ROOT"
  mkdir -p .scripts/lib .scripts/templates message-bus browse-maintenance oauth2-proxy design
  cp "$BATS_TEST_DIRNAME/../lib/production-config.sh" .scripts/lib/
  cp "$BATS_TEST_DIRNAME/../lib/cluster-operation-lock.sh" .scripts/lib/
  cp "$BATS_TEST_DIRNAME/../lib/production-storage.sh" .scripts/lib/
  cp "$BATS_TEST_DIRNAME/../lib/production-restore.sh" .scripts/lib/
  cp "$BATS_TEST_DIRNAME/../validate-production-image-index.sh" .scripts/
  cp "$BATS_TEST_DIRNAME/../validate-backup-snapshot.py" .scripts/
  use_mise_tools
  setup_mock_bin
  export VALUES="$FIXTURE_ROOT/values.yaml"
  export ARTIFACT="ghcr.io/dhhyi/recipe-db-releases@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  export MOCK_FOREIGN=false MOCK_BAD_NODES=false MOCK_LOCK=false MOCK_ROLLOUT=false MOCK_SHAPE=false MOCK_SECRET_ERROR=false
  export MOCK_ABSENT=false MOCK_MEMORY=17179869184 MOCK_PUBLIC=false
  export MOCK_FOREIGN_NAMESPACE=false MOCK_FOREIGN_HELM=false MOCK_HELM_PENDING=false MOCK_HELM_DELAYED=false
  export MOCK_LOCK_OWNER_CHANGE=false
  export MOCK_INCOMPLETE_INDEX=false
  export MOCK_STALE_ROUTES=false
  export MOCK_LAN=false MOCK_NODEPORT=false MOCK_EXTERNAL_IP=false MOCK_SERVICE_TYPE=auto MOCK_ALLOCATE_NODEPORT=false
  export MOCK_HTTPS=false MOCK_FOREIGN_ACME=false
  export MOCK_FOREIGN_ACME_CONTACT=false
  export MOCK_BACKUP=false MOCK_CLEANUP_FAIL=false MOCK_RECOVERY_FAIL=false MOCK_COPY_FAIL=false
  export MOCK_RESTORE=false
  jq -n --arg root "$FIXTURE_ROOT" '{
    target:"local",cluster:"recipe-db-rehearsal",context:"k3d-recipe-db-rehearsal",
    namespace:"recipe-db",origin:"http://127.0.0.1:8080",httpPort:8080,apiPort:6445,
    timeoutSeconds:600,storageClass:"local-path",
    volumes:{recipes:"1Gi",images:"1Gi",ratings:"1Gi",inspirations:"1Gi",
      "image-inline":"256Mi","link-extract":"256Mi",nats:"1Gi",typesense:"1Gi",search:"1Gi",redis:"1Gi",tags:"256Mi"},
    resources:{requests:{cpu:"25m",memory:"32Mi"},limits:{memory:"512Mi"}},
    infrastructure:{traefik:"traefik:v3@sha256:1336e85aaed293bd63d005086e0dd013b04078b26aaeb1c18b26a2f928af7e65",nats:"nats:2.11.0",typesense:"typesense/typesense:30.0",
      maintenance:"nginx:1.28",oauth2Proxy:"quay.io/oauth2-proxy/oauth2-proxy:v7.9.0",redis:"redis:8.0"},
    runtime:{googleOAuthClientId:"explicit.apps.googleusercontent.com",trustedIssuer:"https://accounts.google.com"},
    secrets:{"auth-accounts.json":($root+"/auth-accounts.json"),
      "google-oauth-client-secret":($root+"/google-oauth-client-secret"),
      "oauth2-cookie-secret":($root+"/oauth2-cookie-secret")}
  }' > "$VALUES"
  printf '{"anonymous":{"role":"anonymous"},"tokens":[],"googleAccounts":{}}\n' > auth-accounts.json
  printf 'acme@example.org\n' > acme-account-email
  printf 'private-oauth-client-value-for-tests' > google-oauth-client-secret
  printf 'MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=' > oauth2-cookie-secret
  cat > .scripts/lib/project-metadata.sh << 'EOF'
application_project_metadata_to_jsonl() {
  if [[ $MOCK_BACKUP = true || $MOCK_RESTORE = true ]]; then
    printf '%s\n' \
      '{"name":"recipes","category":"backend","backupRole":"authoritative-read-only","backupData":{"kind":"sqlite","file":"recipes.sqlite3"},"devcontainer":{"ports":[8081],"environment":{}}}' \
      '{"name":"images","category":"backend","backupRole":"cleanup-participant","backupCompact":true,"backupData":{"kind":"images"},"devcontainer":{"ports":[8082],"environment":{}}}' \
      '{"name":"tags","category":"backend","backupRole":"cleanup-participant","backupData":{"kind":"sqlite","file":"tags.sqlite"},"devcontainer":{"ports":[8090],"environment":{}}}' \
      '{"name":"search","category":"backend","backupRole":"derived-stateless","devcontainer":{"ports":[3000],"environment":{}}}' \
      '{"name":"browse","category":"frontend","devcontainer":{"ports":[3000],"environment":{}}}' \
      > "$2"
    return
  fi
  printf '%s\n' \
    '{"name":"recipes","category":"backend","backupRole":"authoritative-read-only","devcontainer":{"ports":[8081],"environment":{}}}' \
    '{"name":"images","category":"backend","backupRole":"cleanup-participant","backupCompact":true,"devcontainer":{"ports":[8082],"environment":{}}}' \
    > "$2"
}
EOF
  cat > .scripts/validate-production-release.sh << 'EOF'
#!/bin/sh
jq -e --arg revision "$2" '.schemaVersion == 1 and .revision == $revision' "$1" > /dev/null
EOF
  printf 'test\n' > message-bus/nats.conf
  printf 'test\n' > browse-maintenance/nginx.conf
  printf 'test\n' > browse-maintenance/unavailable.html
  printf 'test\n' > oauth2-proxy/oauth2-proxy.cfg
  printf 'test\n' > design/nginx.conf
  cat > bin/k3d << 'EOF'
#!/usr/bin/env bash
printf 'k3d %s\n' "$*" >> "$MOCK_LOG"
case "$*" in
  version) echo "k3d version v5.8.3" ;;
  "cluster list -o json")
    if [[ $MOCK_ABSENT = true && ! -f ${MOCK_LOG%/*}/created ]]; then
      echo '[]'
    else
      echo '[{"name":"recipe-db-rehearsal","serversCount":1,"agentsCount":0}]'
    fi ;;
  "cluster create "*) touch "${MOCK_LOG%/*}/created" ;;
  "kubeconfig get "*) echo private-managed-kubeconfig ;;
  "cluster delete "*) ;;
  *) exit 1 ;;
esac
EOF
  cat > bin/docker << 'EOF'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "$MOCK_LOG"
if [[ $1 = info ]]; then echo "$MOCK_MEMORY"; exit; fi
if [[ $MOCK_ABSENT = true && ! -f ${MOCK_LOG%/*}/created ]]; then exit 1; fi
jq -n --arg foreign "$MOCK_FOREIGN" --arg public "$MOCK_PUBLIC" '[
  {Config:{Image:"rancher/k3s:v1.35.5-k3s1",Labels:{
    "recipe-db.managed":(if $foreign == "true" then "foreign" else "rehearsal" end),
    "k3d.cluster":"recipe-db-rehearsal","k3d.role":"server"}},
    State:{Running:true},HostConfig:{PortBindings:{}},Mounts:[]},
  {Config:{Labels:{"k3d.cluster":"recipe-db-rehearsal","k3d.role":"loadbalancer"}},
    State:{Running:true},HostConfig:{PortBindings:{
      "80/tcp":[{HostIp:(if $public == "true" then "0.0.0.0" else "127.0.0.1" end),HostPort:"8080"}],
      "6443/tcp":[{HostIp:"127.0.0.1",HostPort:"6445"}]}},Mounts:[]}
]'
EOF
  cat > bin/kubectl << 'EOF'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >> "$MOCK_LOG"
  [[ $* != *"--resource-version="* ]] || { echo 'unknown flag: --resource-version' >&2; exit 1; }
  case "$*" in
    *" get job backup-cleanup --ignore-not-found -o json"*)
      if [[ -f $MOCK_LOG.cleanup-job ]]; then
        jq -n --arg foreign "${MOCK_FOREIGN_CLEANUP:-false}" '
          {metadata:{labels:{"app.kubernetes.io/part-of":
            (if $foreign == "true" then "foreign" else "recipe-db" end)}}}'
      fi
      exit ;;
    *" delete job backup-cleanup "*)
      [[ ${MOCK_CLEANUP_DELETE_FAIL:-false} != true ]] || exit 1
      rm -f "$MOCK_LOG.cleanup-job"
      exit ;;
    *" get pods -l job-name=backup-cleanup -o json"*)
      if [[ -f $MOCK_LOG.cleanup-job || ${MOCK_CLEANUP_PODS_REMAIN:-false} == true ]]; then
        echo '{"items":[{"metadata":{"name":"cleanup-worker"}}]}'
      else
        echo '{"items":[]}'
      fi
      exit ;;
  esac
  if [[ $MOCK_RESTORE == true ]]; then
    case "$*" in
      *"get deployments,statefulsets,replicasets,replicationcontrollers,daemonsets,jobs,cronjobs,horizontalpodautoscalers,pods -o json")
        if [[ ${MOCK_ABANDON_WORKER:-false} == true ]]; then
          echo '{"items":[{"kind":"Pod","metadata":{"name":"restore-volume-recipes"}}]}'
        elif [[ ${MOCK_ABANDON_WRITER:-false} == true ]]; then
          echo '{"items":[{"kind":"Deployment","spec":{"replicas":1},"status":{"replicas":1}}]}'
        elif [[ ${MOCK_ABANDON_JOB:-false} == true ]]; then
          echo '{"items":[{"kind":"Job","spec":{"suspend":false},"status":{"active":0}}]}'
        else echo '{"items":[{"kind":"Deployment","spec":{"replicas":0},"status":{"replicas":0}},{"kind":"Job","spec":{"suspend":true},"status":{"active":0}}]}'; fi
        exit ;;
      *"get secret recipe-db-routes -o json")
        jq --arg bad "${MOCK_ABANDON_BAD_BARRIER:-false}" '
          if $bad == "true" then .http.routers.graphql={entrypoints:["web"]} else . end |
          {metadata:{labels:{"app.kubernetes.io/part-of":"recipe-db"}},
            data:{"routes.yml":(tojson|@base64)}}' "$MOCK_LOG.restore-routes"
        exit ;;
      *"get configmap recipe-db-restore --ignore-not-found -o json")
        if [[ -f $MOCK_LOG.cluster-restore-state ]]; then
          cat "$MOCK_LOG.cluster-restore-state"
        fi
        exit ;;
      *"apply -f "*restore-state-configmap.json)
        cp "${*: -1}" "$MOCK_LOG.cluster-restore-state"
        exit ;;
      *"get deployments,statefulsets,replicasets,replicationcontrollers,daemonsets,jobs,cronjobs,horizontalpodautoscalers,pods,services,ingresses,configmaps,secrets -o json")
        if [[ ${MOCK_RESTORE_EXISTING:-false} == true ]]; then
          echo '{"items":[{"kind":"Deployment","metadata":{"name":"recipes"}}]}'
        else echo '{"items":[]}'; fi
        exit ;;
      *"get namespace recipe-db --ignore-not-found -o json")
        echo '{"metadata":{"labels":{"app.kubernetes.io/part-of":"recipe-db"}}}'; exit ;;
      *"get pvc -o json") echo '{"items":[]}'; exit ;;
      *"get pvc "*"-o json")
        name="${*: -3:1}"
        if [[ $* == *"--ignore-not-found"* && ! -e $MOCK_LOG.claims ]]; then exit; fi
        jq -n --arg name "$name" --arg drift "${MOCK_RESTORE_PVC_DRIFT:-false}" '
          {metadata:{name:$name,namespace:"recipe-db",uid:(if $drift == "true" then "changed" else $name end),
            labels:{"app.kubernetes.io/part-of":"recipe-db"}},
            spec:{storageClassName:"local-path",accessModes:["ReadWriteOnce"]},status:{phase:"Bound"}}'
        exit ;;
      *"get pv -o json")
        if [[ ${MOCK_RESTORE_RELEASED:-false} == true ]]; then
          echo '{"items":[{"spec":{"claimRef":{"namespace":"recipe-db"}},"status":{"phase":"Released"}}]}'
        else echo '{"items":[]}'; fi
        exit ;;
      *"create -f "*restore-new-claim.yml) touch "$MOCK_LOG.claims"; exit ;;
      *"create -f "*restore-volume-pod.json)
        jq -c . "${*: -1}" >> "$MOCK_LOG.restore-pods"; exit ;;
      *"get pods -o json")
        jq -s '{items:.}' "$MOCK_LOG.restore-pods"; exit ;;
      *"exec deployment/nats -- wget -qO-"*)
        sequence=$(cat "$MOCK_LOG.stream-sequence" 2>/dev/null || echo 0)
        config_requested=false
        [[ $* == *"config=true"* ]] && config_requested=true
        jq -n --argjson sequence "$sequence" --argjson config_requested "$config_requested" '{
          account_details:[{stream_detail:[{
            name:"RECIPE_EVENTS",state:{last_seq:$sequence},consumer_detail:[
              {name:"search-index-v1"} +
                (if $config_requested then {config:{ack_policy:"explicit",filter_subject:"recipes.events.v1"}} else {} end) +
                {ack_floor:{stream_seq:$sequence},num_ack_pending:0,num_pending:0},
              {name:"browse-cache-v1"} +
                (if $config_requested then {config:{ack_policy:"explicit",filter_subject:"recipes.events.v1"}} else {} end) +
                {ack_floor:{stream_seq:$sequence},num_ack_pending:0,num_pending:0}
            ]
          }]}]
        }'
        exit ;;
      *"exec "*restore-volume-*"-- sh -ec"*)
        if [[ ${MOCK_RESTORE_FIND_FAIL:-false} == true ]]; then
          mkdir -p "$FIXTURE_ROOT/find-error"
          printf '#!/bin/sh\nexit 1\n' > "$FIXTURE_ROOT/find-error/find"
          chmod +x "$FIXTURE_ROOT/find-error/find"
          PATH="$FIXTURE_ROOT/find-error:$PATH" sh -ec "${@: -1}"
          exit $?
        fi
        if [[ ${MOCK_RESTORE_NONEMPTY:-} != "" && $* == *"restore-volume-$MOCK_RESTORE_NONEMPTY "* ]]; then exit 1; fi
        exit ;;
      *"exec -i restore-volume-"*"-- tar -xpkf - --numeric-owner -C /data")
        if [[ ${MOCK_RESTORE_IMPORT_FAIL:-false} == true ]]; then exit 1; fi
        name="${*: -8:1}"
        name="${name#restore-volume-}"
        mkdir -p "$FIXTURE_ROOT/imported/$name"
        tar -xpkf - -C "$FIXTURE_ROOT/imported/$name"
        touch "$MOCK_LOG.imported"
        exit ;;
      *"exec restore-volume-"*"-- tar -C /data -cf - .")
        name="${*: -8:1}"
        name="${name#restore-volume-}"
        tar -C "$FIXTURE_ROOT/imported/$name" -cf - .
        exit ;;
      *"exec restore-volume-"*"-- sync") exit ;;
      *"delete pod restore-volume-"*)
        jq -s --arg name "${*: -3:1}" '.[] | select(.metadata.name != $name)' "$MOCK_LOG.restore-pods" \
          > "$MOCK_LOG.restore-pods.next"
        mv "$MOCK_LOG.restore-pods.next" "$MOCK_LOG.restore-pods"; exit ;;
      *"get pod restore-volume-"*) exit ;;
      *"port-forward "*)
        if [[ $* == *"service/browse"* ]]; then port=18082; else port=18081; fi
        echo "Forwarding from 127.0.0.1:$port -> 3000"
        exec sleep 600 ;;
      *"replace -f "*recipe-db-deploy-update.json) cp "${*: -1}" "$MOCK_LOG.lease"; exit ;;
      *"get lease recipe-db-deploy"*)
        if [[ ${MOCK_RESTORE_LOCK_DRIFT:-false} == true && -e $MOCK_LOG.imported ]]; then
          jq '.spec.holderIdentity="foreign-operation"' "$MOCK_LOG.lease"
          exit
        fi ;;
      *"create secret generic recipe-db-routes"*)
        for arg in "$@"; do
          case "$arg" in --from-file=routes.yml=*) cp "${arg#--from-file=routes.yml=}" "$MOCK_LOG.restore-routes" ;; esac
        done
        echo '{"kind":"Secret"}'; exit ;;
      *"get deployments -o json") cat "$MOCK_LOG.restore-deployments"; exit ;;
      *"apply -f "*application.yml)
        yq -o=json -I=0 'select(.kind == "Deployment")' "${*: -1}" | jq -s '{items:map(. + {status:{readyReplicas:.spec.replicas}})}' \
          > "$MOCK_LOG.restore-deployments"; exit ;;
      *"scale deployment/"*"--replicas="*)
        name="${*: -2:1}"; name="${name#deployment/}"; replicas="${*: -1}"; replicas="${replicas#--replicas=}"
        jq -e --arg name "$name" 'any(.items[]; .metadata.name == $name)' \
          "$MOCK_LOG.restore-deployments" > /dev/null || exit 1
        jq --arg name "$name" --argjson replicas "$replicas" '
          (.items[] | select(.metadata.name == $name)) |= (.spec.replicas=$replicas | .status.readyReplicas=$replicas)' \
          "$MOCK_LOG.restore-deployments" > "$MOCK_LOG.restore-deployments.next"
        mv "$MOCK_LOG.restore-deployments.next" "$MOCK_LOG.restore-deployments"; exit ;;
      *"set env deployment/"*"MODE="*)
        name="${*: -3:1}"; name="${name#deployment/}"; mode="${*: -2:1}"; mode="${mode#MODE=}"
        jq --arg name "$name" --arg mode "$mode" '
          (.items[] | select(.metadata.name == $name).spec.template.spec.containers[].env[] |
            select(.name == "MODE").value)=$mode' \
          "$MOCK_LOG.restore-deployments" > "$MOCK_LOG.restore-deployments.next"
        mv "$MOCK_LOG.restore-deployments.next" "$MOCK_LOG.restore-deployments"; exit ;;
    esac
  fi
  if [[ $MOCK_BACKUP = true ]]; then
    handled=false
    case "$*" in
      *" get --raw /api/v1/namespaces/recipe-db/pods?watch=true&resourceVersion=1&timeoutSeconds="*)
        while true; do
          if [[ -f $MOCK_LOG.events ]]; then cat "$MOCK_LOG.events"; fi
          sleep 0.1
        done ;;
      *" get deployments -o json"*)
        jq --arg drift "${MOCK_RECOVERY_DRIFT:-false}" --arg cleaned "$([[ -e $MOCK_LOG.cleaned ]] && echo true || echo false)" '
          if $drift == "true" and $cleaned == "true" then
            (.items[] | select(.metadata.name == "tags").status.readyReplicas)=0
          else . end
        ' "$MOCK_LOG.deployments"
        handled=true ;;
      *" get deployment "*"-o json"*)
        name="${*: -3:1}"
        jq --arg name "$name" '.items[] | select(.metadata.name == $name)' "$MOCK_LOG.deployments"
        handled=true ;;
      *" get configmap recipe-db-release -o json"*)
        jq -n --arg artifact "$ARTIFACT" --arg revision "$MOCK_REVISION" '{data:{artifact:$artifact,revision:$revision}}'
        handled=true ;;
      *" get secret recipe-db-runtime -o json"*)
        jq -n '{metadata:{namespace:"recipe-db",labels:{"app.kubernetes.io/part-of":"recipe-db"}},
          data:{"auth-accounts.json":"e30=","graphql-ingress-secret":"YQ==",
            "typesense-api-key":"YQ==","google-oauth-client-secret":"YQ==","oauth2-cookie-secret":"YQ=="}}'
        handled=true ;;
      *" get service graphql-projection -o json"*)
        echo '{"spec":{"type":"ClusterIP","selector":{"app.kubernetes.io/name":"graphql"},"ports":[{"name":"graphql","port":4000,"targetPort":4000,"protocol":"TCP"}]}}'
        handled=true ;;
      *" get pvc "*"-o json"*)
        pvc="${*: -3:1}"
        if [[ -f $MOCK_LOG.pvcs ]]; then
          jq --arg name "$pvc" --arg drift "${MOCK_PVC_DRIFT:-false}" '
            .items[] | select(.metadata.name == $name) |
            if $drift == "true" then .metadata.uid="changed-claim-uid" else . end
          ' "$MOCK_LOG.pvcs"
        else
          jq -n --arg pvc "$pvc" '{
            metadata:{namespace:"recipe-db",labels:{"app.kubernetes.io/part-of":"recipe-db"}},
            status:{phase:"Bound"},
            spec:{storageClassName:"local-path",accessModes:["ReadWriteOnce"],
              resources:{requests:{storage:"1Gi"}}}
          }'
        fi
        handled=true ;;
      *" get pods "*"-o json"*)
        jq --arg args "$*" '{
          metadata:{resourceVersion:"1"},
          items:[.items[] | . as $deployment |
            select(($args | contains("recipe-db/backup-id=")) | not) |
            select(($args | contains("app.kubernetes.io/name=") | not) or
              ($args | contains("app.kubernetes.io/name=" + $deployment.metadata.name))) |
            range(.spec.replicas) | . as $replica |
            {metadata:{name:($deployment.metadata.name+"-pod"),uid:($deployment.metadata.name+"-"+($deployment.generation|tostring)+"-"+($replica|tostring)),
              labels:{"app.kubernetes.io/name":$deployment.metadata.name}},
              status:{phase:"Running"},spec:{volumes:$deployment.spec.template.spec.volumes}}]
        }' "$MOCK_LOG.deployments"
        handled=true ;;
      *" get pod "*"--ignore-not-found -o json"*) handled=true ;;
      *" apply -f "*backup-cleanup-job.yml)
        touch "$MOCK_LOG.cleanup-job"
        handled=true ;;
      *" get job backup-cleanup -o json"*)
        if [[ $MOCK_CLEANUP_FAIL = true ]]; then
          echo '{"status":{"conditions":[{"type":"Failed","status":"True"}]}}'
        else
          echo '{"status":{"conditions":[{"type":"Complete","status":"True"}]}}'
        fi
        handled=true ;;
      *" wait --for=condition=complete job/backup-cleanup "*)
        if [[ $MOCK_CLEANUP_FAIL = true ]]; then
          rm -f "$FIXTURE_ROOT/tar-data/images/public/stale.png"
          exit 1
        fi
        touch "$MOCK_LOG.cleaned"
        handled=true ;;
      *" rollout status deployment/search "*)
        [[ ${MOCK_PROJECTION_FAIL:-false} != true ]] || exit 1
        handled=true ;;
      *" rollout status deployment/graphql "*)
        if [[ ${MOCK_GRAPHQL_REOPEN_FAIL:-false} = true && -e $MOCK_LOG.reopening ]]; then exit 1; fi
        handled=true ;;
      *" scale deployment/"*"--replicas="*)
        resource="${*: -2:1}"
        service="${resource#deployment/}"
        replicas="${*: -1}"
        if [[ $replicas = --replicas=0 ]]; then
          touch "$MOCK_LOG.$service.stopped"
          forced=${MOCK_FORCED_TERMINATION:-false}
          if [[ $forced = capture ]]; then
            if [[ -e $MOCK_LOG.cleaned ]]; then forced=true; else forced=false; fi
          fi
          jq -c --arg service "$service" --arg forced "$forced" '
            .items[] | select(.metadata.name == $service) | . as $deployment |
            range(.spec.replicas) | . as $replica |
            {type:"DELETED",object:{metadata:{uid:($service+"-"+($deployment.generation|tostring)+"-"+($replica|tostring))},
              status:{containerStatuses:[{state:{terminated:{
                exitCode:(if $forced == "true" then 137 else 0 end)}}}]}}}
          ' "$MOCK_LOG.deployments" >> "$MOCK_LOG.events"
        else
          rm -f "$MOCK_LOG.$service.stopped"
        fi
        jq --arg service "$service" --argjson replicas "${replicas#--replicas=}" '
          (.items[] | select(.metadata.name == $service)) |=
            (.spec.replicas=$replicas | .status.readyReplicas=$replicas | .generation += 1)
        ' "$MOCK_LOG.deployments" > "$MOCK_LOG.deployments.next"
        mv "$MOCK_LOG.deployments.next" "$MOCK_LOG.deployments"
        handled=true ;;
      *" replace -f "*recipe-db-deploy-update.json)
        cp "${*: -1}" "$MOCK_LOG.lease"
        handled=true ;;
      *" set env deployment/graphql MODE=production "*)
        [[ $MOCK_RECOVERY_FAIL != true ]] || exit 1
        touch "$MOCK_LOG.reopening"
        jq '(.items[] | select(.metadata.name == "graphql").spec.template.spec.containers[0].env[0].value)="production"' \
          "$MOCK_LOG.deployments" > "$MOCK_LOG.deployments.next"
        mv "$MOCK_LOG.deployments.next" "$MOCK_LOG.deployments"
        handled=true ;;
      *" set env deployment/"*" MODE="*)
        service="${*: -3:1}"
        service=${service#deployment/}
        mode="${*: -2:1}"
        if [[ $service == graphql && ${MOCK_GRAPHQL_REOPEN_FAIL:-false} = true &&
          -e $MOCK_LOG.reopening ]]; then exit 1; fi
        jq --arg service "$service" --arg mode "${mode#MODE=}" \
          '(.items[] | select(.metadata.name == $service).spec.template.spec.containers[0].env[0].value)=$mode' \
          "$MOCK_LOG.deployments" > "$MOCK_LOG.deployments.next"
        mv "$MOCK_LOG.deployments.next" "$MOCK_LOG.deployments"
        handled=true ;;
      *" create -f "*copy-pod.json)
        pod_file="${*: -1}"
        jq -e '.spec.volumes[0].persistentVolumeClaim.readOnly == true and
          .spec.containers[0].volumeMounts[0].readOnly == true and
          .spec.automountServiceAccountToken == false' "$pod_file" > /dev/null || exit 1
        handled=true ;;
      *" exec backup-copy-"*"sh -ec"*)
        if [[ -n ${MOCK_ARCHIVE_BYTES:-} ]]; then
          printf '%s\n' "$MOCK_ARCHIVE_BYTES"
        else
          service="${*: -5:1}"
          service="${service#backup-copy-}"
          service="${service%-*}"
          tar -C "$FIXTURE_ROOT/tar-data/$service" -cf - . | wc -c
        fi
        handled=true ;;
      *" exec backup-copy-"*"tar -C /data -cf - ."*)
        [[ $MOCK_COPY_FAIL != true ]] || exit 1
        service="${*: -8:1}"
        service="${service#backup-copy-}"
        service="${service%-*}"
        tar -C "$FIXTURE_ROOT/tar-data/$service" -cf - .
        handled=true ;;
    esac
    if $handled; then exit 0; fi
  fi
  case "$*" in
  *"get service traefik -o json"*)
    if [[ ${MOCK_SERVICE_DRIFT:-false} == true ]]; then
      if [[ -e $MOCK_LOG.service-checked ]]; then
        MOCK_EXTERNAL_IP=true
      else
        touch "$MOCK_LOG.service-checked"
      fi
    fi
    jq -n --arg lan "$MOCK_LAN" --arg pi "${MOCK_PI:-false}" --arg type "$MOCK_SERVICE_TYPE" \
      --arg nodeport "$MOCK_NODEPORT" --arg allocate "$MOCK_ALLOCATE_NODEPORT" \
      --arg external "$MOCK_EXTERNAL_IP" --arg https "$MOCK_HTTPS" '
      {spec:{type:(if $type != "auto" then $type
          elif $lan == "true" or $pi != "true" then "LoadBalancer" else "ClusterIP" end),
        allocateLoadBalancerNodePorts:($allocate == "true"),
        externalIPs:(if $external == "true" then ["192.0.2.1"] else [] end),ports:[{port:80} +
          (if $nodeport == "true" then {nodePort:30080} else {} end)] +
          (if $https == "true" then [{port:8081},{port:8443}] else [] end)}}' ;;
  *"config view --minify -o jsonpath="*) printf 'https://127.0.0.1:6445' ;;
  *"get nodes -o json"*)
    if [[ ${MOCK_PI:-false} = true ]]; then
      echo '{"items":[{"metadata":{"name":"recipe-db-pi"},"spec":{"providerID":"k3s://recipe-db-pi"},"status":{"nodeInfo":{"architecture":"arm64"},"conditions":[{"type":"Ready","status":"True"}]}}]}'
      exit
    fi
    jq -n --arg bad "$MOCK_BAD_NODES" '{items:[{metadata:{name:"k3d-recipe-db-rehearsal-server-0"},
      spec:{providerID:(if $bad == "true" then "foreign" else "k3s://k3d-recipe-db-rehearsal-server-0" end)}}]}' ;;
  *"get deployments -o json"*) echo '{"items":[{"metadata":{"name":"nats"}},{"metadata":{"name":"recipes"}},{"metadata":{"name":"search"}}]}' ;;
  *"get storageclass local-path "*)
    echo '{"metadata":{"name":"local-path"},"provisioner":"rancher.io/local-path","reclaimPolicy":"Delete"}' ;;
  *"get storageclass recipe-db-retained "*)
    echo '{"metadata":{"name":"recipe-db-retained","labels":{"app.kubernetes.io/part-of":"recipe-db"}},"provisioner":"rancher.io/local-path","parameters":{"nodePath":"/srv/recipe-db/storage"},"reclaimPolicy":"Retain","volumeBindingMode":"WaitForFirstConsumer","allowedTopologies":[{"matchLabelExpressions":[{"key":"kubernetes.io/hostname","values":["recipe-db-pi"]}]}]}' ;;
  *"patch storageclass "*) echo 'StorageClass fields are immutable' >&2; exit 1 ;;
  *"get persistentvolumeclaims -o json"* | *"get pvc -o json"*)
    if [[ -f $MOCK_LOG.pvcs ]]; then cat "$MOCK_LOG.pvcs"; else echo '{"items":[]}'; fi ;;
  *"get persistentvolumes -o json"* | *"get pv -o json"*)
    if [[ -f $MOCK_LOG.pvs ]]; then cat "$MOCK_LOG.pvs"; else echo '{"items":[]}'; fi ;;
  *"get namespace recipe-db --ignore-not-found -o json"*)
    if [[ $MOCK_FOREIGN_NAMESPACE = true ]]; then
      echo '{"metadata":{"labels":{}}}'
    elif [[ -f $MOCK_LOG.pvcs ]]; then
      echo '{"metadata":{"name":"recipe-db","labels":{"app.kubernetes.io/part-of":"recipe-db"}}}'
    fi ;;
  *"get namespace recipe-db --ignore-not-found -o name"*)
    if [[ -f $MOCK_LOG.pvcs ]]; then echo namespace/recipe-db; fi ;;
  *"get pvc recipe-db-acme --ignore-not-found -o json"*)
    if [[ $MOCK_FOREIGN_ACME == true ]]; then echo '{"metadata":{"labels":{}}}'; fi ;;
  *"get secret recipe-db-acme-contact --ignore-not-found -o json"*)
    if [[ $MOCK_FOREIGN_ACME_CONTACT == true ]]; then echo '{"metadata":{"labels":{}}}'; fi ;;
  *"get helmchartconfig traefik --ignore-not-found -o json"*)
    if [[ $MOCK_FOREIGN_HELM = true ]]; then echo '{"metadata":{"labels":{"owner":"someone-else"}}}'; fi ;;
  *"get deployment traefik -o json"*)
    if [[ $MOCK_HELM_PENDING = true ]]; then echo '{}'; exit; fi
    if [[ $MOCK_HELM_DELAYED = true && ! -f ${MOCK_LOG%/*}/helm-observed ]]; then
      touch "${MOCK_LOG%/*}/helm-observed"
      echo '{}'
      exit
    fi
    checksum=$(cat "$MOCK_LOG.route-checksum")
    if [[ $MOCK_STALE_ROUTES = true && ! -f ${MOCK_LOG%/*}/routes-observed ]]; then
      touch "${MOCK_LOG%/*}/routes-observed"
      checksum=old-routes
    fi
    echo '{"spec":{"template":{"spec":{"containers":[{
      "name":"traefik","image":"docker.io/traefik:v3@sha256:1336e85aaed293bd63d005086e0dd013b04078b26aaeb1c18b26a2f928af7e65",
      "args":["--providers.file.filename=/etc/recipe-db/routes.yml"],
      "ports":[{"containerPort":3000}],"volumeMounts":[{"mountPath":"/etc/recipe-db"}]}],
      "volumes":[{"name":"recipe-db-routes","secret":{"secretName":"recipe-db-routes"}}]}}}}' |
      jq --arg checksum "$checksum" --argjson https "$(jq 'has("httpsStaging")' "$VALUES")" '
        .spec.template.metadata.annotations["recipe-db/routes-checksum"] = $checksum |
        if $https then
          .spec.template.spec.containers[0].args += ["--certificatesresolvers.letsencrypt.acme.email=$(ACME_ACCOUNT_EMAIL)"] |
          .spec.template.spec.containers[0].env = [{name:"ACME_ACCOUNT_EMAIL",
            valueFrom:{secretKeyRef:{name:"recipe-db-acme-contact",key:"email"}}}]
        else . end' ;;
  *"create -f "*lease.json*)
    [[ $MOCK_LOCK != true ]] || exit 1
    lock_file="${*: -1}"
    jq '.metadata.namespace="kube-system" | .metadata.uid="lease-uid" |
      .metadata.resourceVersion="42"' "$lock_file" > "$MOCK_LOG.lease"
    ;;
  *"get lease recipe-db-deploy"*)
    [[ -f $MOCK_LOG.lease ]] || exit 0
    if [[ $MOCK_LOCK_OWNER_CHANGE = true ]]; then
      jq '.spec.holderIdentity="foreign-operation"' "$MOCK_LOG.lease"
    else
      cat "$MOCK_LOG.lease"
    fi ;;
  *"delete --raw /apis/coordination.k8s.io/v1/namespaces/kube-system/leases/recipe-db-deploy"*)
    jq -e --slurpfile current "$MOCK_LOG.lease" '
      .preconditions.uid == $current[0].metadata.uid and
      .preconditions.resourceVersion == $current[0].metadata.resourceVersion
    ' "${*: -1}" > /dev/null || exit 1
    rm -f "$MOCK_LOG.lease" ;;
  *"rollout status "*) [[ $MOCK_ROLLOUT != true ]] ;;
  *"create secret generic recipe-db-routes"*)
    for argument in "$@"; do
      case "$argument" in
        --from-file=routes.yml=*)
          route_file=${argument#--from-file=routes.yml=}
          jq '.http.routers' "$route_file" > "$MOCK_LOG.routers"
          jq -e --slurpfile config "${route_file%/*}/config.json" --rawfile ingress "${route_file%/*}/graphql-ingress-secret" \
            '.http.services.recipes.loadBalancer.servers[0].url == "http://recipes.recipe-db.svc.cluster.local:4000"
            and (if ($config[0].runtime | has("googleOAuthClientId")) | not then
              .http.middlewares["oauth2-forward-auth"] == null and
              .http.routers["oauth2-public"] == null and
              .http.routers["graphql-cookie"] == null and
              .http.services["oauth2-proxy"] == null
            else .http.middlewares["oauth2-forward-auth"].forwardAuth.address == "http://oauth2-proxy.recipe-db.svc.cluster.local/oauth2/auth" end)
            and .http.routers["graphql-internal"] == {
              rule:"PathPrefix(`/graphql`)",entrypoints:["rest-internal"],
              service:"recipe-db-graphql-projection",middlewares:["graphql-ingress"]}
            and .http.services["recipe-db-graphql-projection"].loadBalancer.servers[0].url ==
              "http://graphql-projection.recipe-db.svc.cluster.local:4000"
            and .http.routers.graphql.entrypoints == ["web"]
            and .http.middlewares["graphql-ingress"].headers.customRequestHeaders["X-Internal-Ingress-Token"] == ($ingress | rtrimstr("\n"))' \
            "$route_file" > /dev/null || exit 1 ;;
      esac
    done
    echo '{"kind":"Secret","data":{}}' ;;
  *"create secret generic recipe-db-runtime"*)
    for argument in "$@"; do
      case "$argument" in
        --from-file=graphql-ingress-secret=*)
          jq -eRs 'test("^[A-Za-z0-9_-]{43}\\z")' \
            "${argument#--from-file=graphql-ingress-secret=}" > /dev/null || exit 1 ;;
        --from-file=typesense-api-key=*)
          path=${argument#--from-file=typesense-api-key=}
          jq -eRs 'test("^[0-9a-f]{64}\\n?\\z")' "$path" > /dev/null || exit 1
          sha256sum "$path" | cut -d ' ' -f1 >> "$MOCK_LOG.typesense-key-checksums"
          sha256sum "${path%/*}/template-values.json" | cut -d ' ' -f1 >> "$MOCK_LOG.input-checksums"
          sha256sum "${path%/*}/rendered-base.yml" | cut -d ' ' -f1 >> "$MOCK_LOG.render-checksums" ;;
        --from-file=oauth2-cookie-secret=*)
          jq -eRs 'test("^[A-Za-z0-9_-]+$")' \
            "${argument#--from-file=oauth2-cookie-secret=}" > /dev/null || exit 1 ;;
      esac
    done
    echo '{"kind":"Secret","data":{}}' ;;
  *"create namespace "* | *"create secret "*) echo '{"kind":"Secret","data":{}}' ;;
  *"apply -f -")
    cat > /dev/null
    if [[ $MOCK_SECRET_ERROR = true ]]; then
      # Namespace creation is also piped through apply; fail only after acquiring the lock.
      if grep -q 'create -f .*lease.json' "$MOCK_LOG"; then
        echo 'unsafe-private-secret-contents' >&2
        exit 1
      fi
    fi ;;
  *"apply -f "*infrastructure.yml)
    last="${*: -1}"
    if yq -e 'select(.metadata.namespace != "kube-system")' "$last" > /dev/null; then exit 1; fi
    yq -r '.spec.valuesContent | from_yaml | .deployment.podAnnotations."recipe-db/routes-checksum"' \
      "$last" > "$MOCK_LOG.route-checksum"
    cat "$MOCK_LOG.route-checksum" >> "$MOCK_LOG.route-checksums"
    [[ $* == *"--namespace kube-system apply"* ]] ;;
  *"apply -f "*application.yml)
    if [[ -f $MOCK_LOG.cleanup-job ]]; then
      echo 'backup-cleanup Job template is immutable' >&2
      exit 1
    fi
    last="${*: -1}"
    if yq -e 'select(.metadata.namespace == "kube-system")' "$last" > /dev/null; then exit 1; fi
    yq -r 'select(.kind == "Deployment").spec.template.metadata.annotations."recipe-db/secrets-checksum"' \
      "$last" >> "$MOCK_LOG.checksums"
    if [[ ${MOCK_PI:-false} = true ]]; then
      yq -o=json -I=0 'select(.kind == "PersistentVolumeClaim")' "$last" > "$MOCK_LOG.applied-pvcs"
    fi ;;
  *"get deployments,pods,jobs,pvc"* | *"get events "*) echo safe-status ;;
  *"config current-context") echo explicit-pi ;;
  *"config view --minify --flatten --raw") echo private-pi-kubeconfig ;;
  *) ;;
esac
EOF
  cat > bin/oras << 'EOF'
#!/usr/bin/env bash
printf 'oras %s\n' "$*" >> "$MOCK_LOG"
if [[ $1 = manifest ]]; then
  if [[ $3 == ghcr.io/dhhyi/recipe-db-releases@* ]]; then
    jq -n --arg shape "$MOCK_SHAPE" --arg revision "$MOCK_REVISION" '{
      schemaVersion:2,artifactType:"application/vnd.dhhyi.recipe-db.release.v1+json",
      annotations:{"org.opencontainers.image.source":"https://github.com/dhhyi/recipe-db",
        "org.opencontainers.image.revision":$revision},
      layers:[{mediaType:"application/json",digest:("sha256:"+("b"*64)),size:100,
        annotations:{"org.opencontainers.image.title":(if $shape == "true" then "../escape" else "release.json" end)}}]}'
  else
    jq -n --arg incomplete "$MOCK_INCOMPLETE_INDEX" '{schemaVersion:2,manifests:(
      [{platform:{os:"linux",architecture:"amd64"},digest:("sha256:"+("c"*64))},
       {platform:{os:"unknown",architecture:"unknown"},digest:("sha256:"+("d"*64))}] +
      (if $incomplete == "true" then [] else
        [{platform:{os:"linux",architecture:"arm64"},digest:("sha256:"+("e"*64))}] end))}'
  fi
else
  [[ $# == 4 && $1 == pull && $2 == ghcr.io/dhhyi/recipe-db-releases@sha256:* && $3 == --output ]] || exit 1
  while [[ $1 != --output ]]; do shift; done
  jq -n --arg revision "$MOCK_REVISION" '{schemaVersion:1,revision:$revision,images:{
    recipes:("ghcr.io/dhhyi/recipe-db-recipes@sha256:"+("b"*64)),
    images:("ghcr.io/dhhyi/recipe-db-images@sha256:"+("b"*64)),
    graphql:("ghcr.io/dhhyi/recipe-db-graphql@sha256:"+("b"*64)),
    tags:("ghcr.io/dhhyi/recipe-db-tags@sha256:"+("b"*64)),
    search:("ghcr.io/dhhyi/recipe-db-search@sha256:"+("b"*64)),
    browse:("ghcr.io/dhhyi/recipe-db-browse@sha256:"+("b"*64))}}' > "$2/release.json"
fi
EOF
  cat > bin/ytt << 'EOF'
#!/usr/bin/env bash
printf 'ytt %s\n' "$*" >> "$MOCK_LOG"
while [[ $1 != --data-values-file ]]; do shift; done
if jq -e 'has("config")' "$2" > /dev/null; then
  jq -e 'keys == ["artifact","config","files","projects","release"]
    and (.files | keys) == ["designNginx","maintenanceHtml","maintenanceNginx","nats","oauthConfig"]' "$2" > /dev/null || exit 1
  if [[ $MOCK_RESTORE == true ]]; then
    jq -c '. as $input |
      (["graphql","recipes","images","tags","search","browse","nats","typesense","browse-maintenance"] +
        (if .config.runtime.googleOAuthClientId then ["redis","oauth2-proxy"] else [] end))[] |
      . as $name | select($name != (env.MOCK_RESTORE_MISSING_WORKLOAD // "")) |
      {apiVersion:"apps/v1",kind:"Deployment",metadata:{name:$name,namespace:"recipe-db"},
      spec:{replicas:1,template:{metadata:{annotations:{"recipe-db/release":$input.artifact}},
      spec:{containers:[{name:$name,image:($input.release.images[$name] // "infrastructure"),
        env:([{name:"MODE",value:"production"}] +
          (if $name == "browse" then [{name:"GRAPHQL_URL",value:"http://traefik/graphql"}] else [] end))}]}}}}' "$2" | while IFS= read -r doc; do
        printf '%s\n---\n' "$doc"
      done
    jq -c '.config.volumes | keys[] | {apiVersion:"v1",kind:"PersistentVolumeClaim",
      metadata:{name:.,namespace:"recipe-db"},spec:{}}' "$2" | while IFS= read -r doc; do
        printf '%s\n---\n' "$doc"
      done
    printf 'apiVersion: batch/v1\nkind: Job\nmetadata:\n  name: nats-init\n  namespace: recipe-db\n---\n'
  elif [[ $MOCK_BACKUP = true ]]; then
    printf 'apiVersion: batch/v1\nkind: Job\nmetadata:\n  name: backup-cleanup\n  namespace: recipe-db\n  labels:\n    app.kubernetes.io/part-of: recipe-db\nspec:\n  suspend: true\n'
  else
    jq -n --arg config "${MOCK_RENDERED_CONFIG:-original}" \
      '{apiVersion:"v1",kind:"ConfigMap",metadata:{name:"release"},data:{config:$config}}' | yq -P
    printf '%s\n' '---'
    printf 'apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: recipes\nspec:\n  template:\n    metadata:\n      annotations: {}\n'
  fi
  if [[ ${MOCK_PI:-false} = true ]]; then
    while IFS= read -r name; do
      printf '%s\n' '---'
      jq --arg name "$name" '{
        apiVersion:"v1",kind:"PersistentVolumeClaim",
        metadata:{name:$name,namespace:.config.namespace,
          labels:{"app.kubernetes.io/part-of":"recipe-db"}},
        spec:{storageClassName:.config.storageClass,accessModes:["ReadWriteOnce"],
          volumeMode:"Filesystem",resources:{requests:{storage:.config.volumes[$name]}}}
      }' "$2"
    done < <(jq -r '.config.volumes | keys[]' "$2")
  fi
  printf '%s\n' '---' 'apiVersion: helm.cattle.io/v1' 'kind: HelmChartConfig' 'metadata:' '  name: traefik' '  namespace: kube-system' 'spec:' '  valuesContent: "deployment: {}"'
else
  jq -e --slurpfile config "$VALUES" '
    has("googleOAuthClientId") and
    .googleOAuthClientId == ($config[0].runtime.googleOAuthClientId // "")
  ' "$2" > /dev/null || exit 1
  cat << 'YAML'
http:
  routers:
    graphql:
      rule: PathPrefix(`/graphql`)
      entrypoints: [web]
      priority: 100
      service: recipe-db-graphql
      middlewares: [graphql-ingress]
    graphql-cookie:
      rule: PathPrefix(`/graphql`) && HeaderRegexp(`Cookie`, `(^|;\s*)_oauth2_proxy(_[^=;\s]*)?(=|;|\s|$)`)
      entrypoints: [web]
      priority: 200
      service: recipe-db-graphql
      middlewares: [oauth2-forward-auth, graphql-ingress]
    graphql-bearer:
      rule: PathPrefix(`/graphql`) && HeaderRegexp(`Authorization`, `.*`)
      entrypoints: [web]
      priority: 300
      service: recipe-db-graphql
      middlewares: [graphql-ingress]
    oauth2-public:
      rule: PathRegexp(`^/oauth2/(start|callback|sign_in|sign_out)$`)
      entrypoints: [web]
      priority: 400
      service: oauth2-proxy
      middlewares: [identity-strip]
    frontend:
      rule: PathPrefix(`/`)
      entrypoints: [web]
      service: recipe-db-frontend
      middlewares: [frontend-compress, browse-unavailable]
    design:
      rule: PathPrefix(`/design/`)
      entrypoints: [web]
      service: recipe-db-design
    images-public:
      rule: PathPrefix(`/public/`)
      entrypoints: [web]
      service: recipe-db-images
    recipes-edit:
      rule: PathPrefix(`/edit`)
      entrypoints: [web]
      service: recipe-db-recipes-edit
      middlewares: [recipes-edit-strip]
    images-edit:
      rule: PathPrefix(`/images`)
      entrypoints: [web]
      service: recipe-db-images-edit
    mcp:
      rule: PathPrefix(`/mcp`)
      entrypoints: [web]
      service: recipe-db-mcp
  middlewares:
    oauth2-forward-auth:
      forwardAuth:
        address: http://oauth2-proxy/oauth2/auth
  services:
    oauth2-proxy:
      loadBalancer:
        servers:
          - url: http://oauth2-proxy:4180
    recipes:
      loadBalancer:
        servers:
          - url: http://recipes:4000
YAML
fi
EOF
  chmod +x bin/*
  mkdir -p "$FIXTURE_ROOT/tar-data/recipes" "$FIXTURE_ROOT/tar-data/tags" \
    "$FIXTURE_ROOT/tar-data/images/public" "$FIXTURE_ROOT/tar-data/images/manifests" "$FIXTURE_ROOT/backups"
  printf 'SQLite format 3\000fixture\n' > "$FIXTURE_ROOT/tar-data/recipes/recipes.sqlite3"
  printf 'SQLite format 3\000fixture\n' > "$FIXTURE_ROOT/tar-data/tags/tags.sqlite"
  printf 'sidecar\n' > "$FIXTURE_ROOT/tar-data/tags/tags.sqlite-wal"
  jq -n --arg artifact "$ARTIFACT" '{
    items: [{name:"graphql",claim:null},{name:"recipes",claim:"recipes"},
      {name:"images",claim:"images"},{name:"tags",claim:"tags"},
      {name:"search",claim:null},{name:"browse",claim:null}] | map({
      metadata:{name:.name},generation:1,spec:{replicas:1,template:{
        metadata:{annotations:{"recipe-db/release":$artifact}},spec:{
          containers:[{name:.name,image:("ghcr.io/dhhyi/recipe-db-"+.name+"@sha256:"+("b"*64)),
            env:[{name:"MODE",value:"production"}],
            volumeMounts:(if .claim == null then [] else [{name:"data",mountPath:"/data"}] end)}],
          volumes:(if .claim == null then [] else [{name:"data",persistentVolumeClaim:{claimName:.claim}}] end)}}},
      status:{readyReplicas:1}})}' > "$MOCK_LOG.deployments"
  git init -q
  git add .scripts/lib/project-metadata.sh message-bus/nats.conf \
    browse-maintenance/nginx.conf browse-maintenance/unavailable.html oauth2-proxy/oauth2-proxy.cfg design/nginx.conf
  git -c user.name=Test -c user.email=test@example.invalid commit -qm 'Fixture release inputs'
  export MOCK_REVISION
  MOCK_REVISION=$(git rev-parse HEAD)
}

set_value() {
  jq "$1" "$VALUES" > values.next
  mv values.next "$VALUES"
}
