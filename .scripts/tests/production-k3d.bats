#!/usr/bin/env bats
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
  export MOCK_LAN=false MOCK_NODEPORT=false
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
      "graphql-ingress-secret":($root+"/graphql-ingress-secret"),
      "typesense-api-key":($root+"/typesense-api-key"),
      "google-oauth-client-secret":($root+"/google-oauth-client-secret"),
      "oauth2-cookie-secret":($root+"/oauth2-cookie-secret")}
  }' > "$VALUES"
  printf '{"anonymous":{"role":"anonymous"},"tokens":[],"googleAccounts":{}}\n' > auth-accounts.json
  printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > graphql-ingress-secret
  printf 'private-typesense-value-for-tests' > typesense-api-key
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
      *" get pods -l job-name=backup-cleanup -o json"*)
        if [[ -f $MOCK_LOG.cleanup-job ]]; then
          echo '{"items":[{"metadata":{"name":"cleanup-worker"}}]}'
        else
          echo '{"items":[]}'
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
      *" get job backup-cleanup --ignore-not-found -o json"*)
        if [[ -f $MOCK_LOG.cleanup-job ]]; then
          echo '{"metadata":{"labels":{"app.kubernetes.io/part-of":"recipe-db"}}}'
        fi
        handled=true ;;
      *" apply -f "*backup-cleanup-job.yml)
        touch "$MOCK_LOG.cleanup-job"
        handled=true ;;
      *" delete job backup-cleanup "*)
        [[ ${MOCK_CLEANUP_DELETE_FAIL:-false} != true ]] || exit 1
        rm -f "$MOCK_LOG.cleanup-job"
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
    jq -n --arg lan "$MOCK_LAN" --arg nodeport "$MOCK_NODEPORT" --arg https "$MOCK_HTTPS" '
      {spec:{type:(if $lan == "true" then "LoadBalancer" else "ClusterIP" end),
        allocateLoadBalancerNodePorts:false,ports:[{port:80} +
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
            and (if $config[0].runtime.authMode == "token-only" then
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
    jq -c '. as $input | ["graphql","recipes","images","tags","search","browse","nats","typesense","redis","browse-maintenance"][] |
      . as $name | {apiVersion:"apps/v1",kind:"Deployment",metadata:{name:$name,namespace:"recipe-db"},
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
    printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: release\n---\napiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: recipes\nspec:\n  template:\n    metadata:\n      annotations: {}\n'
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
  cat << 'YAML'
http:
  routers:
    graphql:
      rule: PathPrefix(`/graphql`)
      entrypoints: [web]
      service: recipe-db-graphql
      middlewares: [graphql-ingress]
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

@test "HTTPS staging rejects unsupported deployment modes before connection" {
  set_value '.httpsStaging={hostname:"recipes.example.org",acmeEnvironment:"production"}'
  run bash .scripts/production-k3d.sh render "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  [[ $output == *"invalid or incomplete production values"* ]]
  run ! grep -q 'kubectl' "$MOCK_LOG"
  run ! grep -q 'oras' "$MOCK_LOG"
}

@test "HTTPS staging rejects unsafe hostname and unknown CA environment before connection" {
  token_only_values
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
  token_only_values
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
  token_only_values
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
  [[ $output == *"requested private exposure"* ]]
}

token_only_values() {
  export MOCK_PI=true
  set_value '.target="pi" | .cluster="recipe-db-pi" | .context="explicit-pi" |
    .storageClass="recipe-db-retained" |
    .piStorage={node:"recipe-db-pi",expectedRootUuid:"02f61d5e-92cb-4f9c-a781-099d97795020",dataRoot:"/srv/recipe-db"} |
    .runtime.authMode="token-only" | .runtime.googleOAuthClientId="" |
    .secrets."acme-account-email"=(.secrets."auth-accounts.json" | sub("auth-accounts.json$"; "acme-account-email")) |
    del(.secrets."google-oauth-client-secret", .secrets."oauth2-cookie-secret")'
  printf '{"anonymous":{"role":"anonymous"},"tokens":[{"id":"rehearsal","secret":"private-owner-token","role":"owner"}],"googleAccounts":{}}\n' > auth-accounts.json
}

@test "application exposure is independent of authorization policy" {
  token_only_values
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
  token_only_values
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
  token_only_values
  set_value '.origin="http://recipe-pi.home" | .runtime.ingressMode="private-lan" |
    .httpsStaging={hostname:"recipes.example.org",acmeEnvironment:"production"}'
  export MOCK_FOREIGN_ACME_CONTACT=true
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  [[ $output == *"unowned ACME contact Secret"* ]]
  run ! grep -q 'create secret' "$MOCK_LOG"
}

@test "preview and renewal rehearsal reject unsafe CA and flag combinations" {
  token_only_values
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
  token_only_values
  printf '{"anonymous":{"role":"anonymous"},"tokens":[],"googleAccounts":{}}\n' > auth-accounts.json
  set_value '.origin="http://recipe-pi.home" | .runtime.ingressMode="private-lan" |
    .httpsStaging={hostname:"recipes.example.org",acmeEnvironment:"production",exposeApplication:true}'
  export MOCK_LAN=true MOCK_HTTPS=true
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  jq -e '
    . as $routers |
    [to_entries[] | select(.value.entrypoints | index("websecure"))] as $secure |
    ($secure | map(.key) | sort) == ["preview-design","preview-frontend","preview-graphql","preview-images-edit","preview-images-public","preview-mcp","preview-recipes-edit"]
    and all($secure[]; .value.rule | startswith("Host(`recipes.example.org`) && "))
    and all($secure[]; .value.middlewares[0] == "identity-strip")
    and all($secure[]; .value.tls.certResolver == "letsencrypt")
    and .["preview-graphql"].middlewares == ["identity-strip","graphql-ingress"]
    and .["preview-frontend"].middlewares == ["identity-strip","frontend-compress","browse-unavailable"]
    and all($secure[]; .key as $name |
      .value.rule == ("Host(`recipes.example.org`) && (" + $routers[($name | ltrimstr("preview-"))].rule + ")"))
    and .["preview-recipes-edit"].middlewares == ["identity-strip","recipes-edit-strip"]
    and .["preview-mcp"].service == .mcp.service
    and .graphql.entrypoints == ["web"]
    and .["graphql-internal"].entrypoints == ["rest-internal"]
    and all(.[]; (.entrypoints | index("staging-http")) == null)
  ' "$MOCK_LOG.routers"
}

@test "anonymous-only policy deploys without extra flags and survives public shutdown" {
  token_only_values
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

@test "token-only deployment accepts member tokens without requiring an owner" {
  token_only_values
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

@test "token-only Pi deployment requires no OAuth secrets and strips OAuth routing" {
  token_only_values
  rm google-oauth-client-secret oauth2-cookie-secret
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  run ! grep -q -- '--from-file=google-oauth-client-secret' "$MOCK_LOG"
  run ! grep -q -- '--from-file=oauth2-cookie-secret' "$MOCK_LOG"
}

@test "Pi deploy preserves verified legacy bound claim classes before applying manifests" {
  token_only_values
  legacy_pi_claims
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  jq -s -e 'length == 11 and
    all(.[]; .spec.storageClassName ==
      (if .metadata.name == "recipes" or .metadata.name == "images" or .metadata.name == "tags"
       then "local-path" else "recipe-db-retained" end))' "$MOCK_LOG.applied-pvcs"
  run ! grep -q 'patch storageclass' "$MOCK_LOG"
}

@test "Pi backup accepts identity-verified legacy bound claims" {
  export MOCK_BACKUP=true
  token_only_values
  legacy_pi_claims
  run bash .scripts/production-k3d.sh backup "$VALUES" "$ARTIFACT" "$FIXTURE_ROOT/snapshot"
  [ "$status" -eq 0 ]
  [ -f "$FIXTURE_ROOT/snapshot/manifest.json" ]
  run ! grep -q 'patch storageclass' "$MOCK_LOG"
}

@test "Pi backup refuses a legacy claim identity change after storage preflight" {
  export MOCK_BACKUP=true MOCK_PVC_DRIFT=true
  token_only_values
  legacy_pi_claims
  run bash .scripts/production-k3d.sh backup "$VALUES" "$ARTIFACT" "$FIXTURE_ROOT/snapshot"
  [ "$status" -ne 0 ]
  [ ! -e "$FIXTURE_ROOT/snapshot" ]
  run ! grep -Eq 'set env deployment/|exec backup-copy-' "$MOCK_LOG"
}

@test "token-only mode refuses non-loopback origins and local targets" {
  token_only_values
  set_value '.origin="http://192.168.1.218:8080"'
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  set_value '.origin="http://127.0.0.1:8080" | .target="local"'
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  run ! grep -q 'create secret' "$MOCK_LOG"
}

@test "private LAN token rehearsal is explicit and refuses public origins and NodePorts" {
  token_only_values
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
  set_value '.runtime.authMode="google"'
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
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

@test "lifecycle permits the checked-in OAuth placeholder but application rendering fails closed" {
  set_value '.runtime.googleOAuthClientId="replace-with-real-google-oauth-client-id"'
  run bash .scripts/production-k3d.sh create "$VALUES"
  [ "$status" -eq 0 ]
  run bash .scripts/production-k3d.sh status "$VALUES"
  [ "$status" -eq 0 ]
  run bash .scripts/production-k3d.sh render "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  [[ $output == *"invalid or incomplete production values"* ]]
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
  for expression in 'del(.runtime.googleOAuthClientId)' '.runtime.extra="guess"' '.volumes.auth="1Gi"' '.origin="http://0.0.0.0:8080"' '.infrastructure.redis="redis:latest"' '.secrets["typesense-api-key"]="relative"'; do
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
  rm auth-accounts.json graphql-ingress-secret typesense-api-key google-oauth-client-secret oauth2-cookie-secret
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

@test "application checksums are stable across identical deploys and change for rotated staged secrets" {
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  jq '.anonymous.displayName="Updated"' auth-accounts.json > accounts.next
  mv accounts.next auth-accounts.json
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$MOCK_LOG.checksums")" -eq 3 ]
  [ "$(sed -n '1p' "$MOCK_LOG.checksums")" = "$(sed -n '2p' "$MOCK_LOG.checksums")" ]
  [ "$(sed -n '1p' "$MOCK_LOG.checksums")" != "$(sed -n '3p' "$MOCK_LOG.checksums")" ]
  grep -Eq '^[0-9a-f]{64}$' "$MOCK_LOG.checksums"
  run ! grep -q 'rollout restart' "$MOCK_LOG"
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
  [ "$(sed -n '1p' "$MOCK_LOG.checksums")" = "$(sed -n '2p' "$MOCK_LOG.checksums")" ]
  [ "$(sed -n '1p' "$MOCK_LOG.checksums")" != "$(sed -n '3p' "$MOCK_LOG.checksums")" ]
  [ "$(sed -n '3p' "$MOCK_LOG.checksums")" != "$(sed -n '4p' "$MOCK_LOG.checksums")" ]
  [ "$(sed -n '4p' "$MOCK_LOG.checksums")" != "$(sed -n '5p' "$MOCK_LOG.checksums")" ]
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

@test "ingress secret rotation updates Traefik pod checksum and waits past stale deployment" {
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' > graphql-ingress-secret
  export MOCK_STALE_ROUTES=true
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  [ "$(sed -n '1p' "$MOCK_LOG.route-checksums")" = "$(sed -n '2p' "$MOCK_LOG.route-checksums")" ]
  [ "$(sed -n '1p' "$MOCK_LOG.route-checksums")" != "$(sed -n '3p' "$MOCK_LOG.route-checksums")" ]
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
  printf 'short' > graphql-ingress-secret
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  [[ $output == *"invalid secret format"* ]]
  [[ $output != *short* ]]
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
  set_value '.target="pi" | .context="explicit-pi" | .storageClass="recipe-db-retained"'
  run bash .scripts/production-k3d.sh status "$VALUES"
  [ "$status" -eq 0 ]
  grep -q '^kubectl --context explicit-pi config view --minify --flatten --raw$' "$MOCK_LOG"
  run ! grep -q '^k3d' "$MOCK_LOG"
}

@test "backup uses the deploy Lease, GraphQL barrier, metadata-selected PVCs and read-only copies" {
  export MOCK_BACKUP=true
  local snapshot="$FIXTURE_ROOT/backups/snapshot-success"

  run bash .scripts/production-k3d.sh backup "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -eq 0 ]
  [ -f "$snapshot/manifest.json" ]
  [ ! -e "$snapshot/backup-state.json" ]
  jq -e --arg artifact "$ARTIFACT" --arg revision "$MOCK_REVISION" '
    .format == "recipe-db-pvc-snapshot" and .formatVersion == 1
    and .source.artifact == $artifact and .source.revision == $revision
    and any(.inventory[]; .service == "tags" and .role == "cleanup-participant")
    and all(.inventory[]; (.sha256 | test("^[0-9a-f]{64}$")) and .sizeBytes > 0)
  ' "$snapshot/manifest.json" > /dev/null
  [ ! -e "$MOCK_LOG.lease" ]
  grep -q 'get --raw /api/v1/namespaces/recipe-db/pods?watch=true&resourceVersion=1&timeoutSeconds=600' "$MOCK_LOG"
  local barrier scale_normal backup_mode cleanup copy last_normal_stop
  barrier=$(grep -n 'set env deployment/graphql MODE=backup' "$MOCK_LOG" | head -n 1 | cut -d: -f1)
  scale_normal=$(grep -n 'scale deployment/recipes --replicas=0' "$MOCK_LOG" | head -n 1 | cut -d: -f1)
  backup_mode=$(grep -n 'set env deployment/recipes MODE=backup' "$MOCK_LOG" | head -n 1 | cut -d: -f1)
  last_normal_stop=$(awk -v limit="$backup_mode" 'NR < limit && /scale deployment\/(recipes|images|tags) --replicas=0/ {line=NR} END {print line}' "$MOCK_LOG")
  cleanup=$(grep -n 'wait --for=condition=complete job/backup-cleanup' "$MOCK_LOG" | head -n 1 | cut -d: -f1)
  copy=$(grep -n 'create -f .*copy-pod.json' "$MOCK_LOG" | head -n 1 | cut -d: -f1)
  [ "$barrier" -lt "$scale_normal" ]
  [ "$last_normal_stop" -lt "$backup_mode" ]
  [ "$backup_mode" -lt "$cleanup" ]
  [ "$cleanup" -lt "$copy" ]
  [ "$(grep -c 'create -f .*copy-pod.json' "$MOCK_LOG")" -eq 3 ]
  [ "$(grep -c ' MODE=production ' "$MOCK_LOG")" -ge 4 ]
  grep -q 'scale deployment/recipes --replicas=1' "$MOCK_LOG"
}

@test "backup refuses deployment contention before changing GraphQL or backends" {
  export MOCK_BACKUP=true MOCK_LOCK=true
  local snapshot="$FIXTURE_ROOT/backups/snapshot-locked"

  run bash .scripts/production-k3d.sh backup "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -ne 0 ]
  [[ $output == *"cannot be acquired"* ]]
  [ ! -e "$snapshot/manifest.json" ]
  run ! grep -Eq 'set env|scale deployment' "$MOCK_LOG"
}

@test "backup cleanup exhaustion restores production and never publishes a snapshot" {
  export MOCK_BACKUP=true MOCK_CLEANUP_FAIL=true
  printf 'stale image purged before another cleanup operation failed' > "$FIXTURE_ROOT/tar-data/images/public/stale.png"
  local snapshot="$FIXTURE_ROOT/backups/snapshot-cleanup-failed"

  run bash .scripts/production-k3d.sh backup "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -ne 0 ]
  [[ $output == *"no complete snapshot was published"* ]]
  [ ! -e "$snapshot/manifest.json" ]
  [ ! -e "$snapshot/recipes.tar" ]
  [ ! -e "$FIXTURE_ROOT/tar-data/images/public/stale.png" ]
  [ "$(grep -c 'wait --for=condition=complete job/backup-cleanup' "$MOCK_LOG")" -eq 1 ]
  [ ! -e "$MOCK_LOG.lease" ]
  grep -q 'set env deployment/graphql MODE=production' "$MOCK_LOG"
  jq -e '.status == "failed" and .phase == "safely-recovered"' \
    "$snapshot/backup-state.json" > /dev/null
}

@test "backup copy failure restores production and publishes no manifest" {
  export MOCK_BACKUP=true MOCK_COPY_FAIL=true
  local snapshot="$FIXTURE_ROOT/backups/snapshot-copy-failed"

  run bash .scripts/production-k3d.sh backup "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -ne 0 ]
  [[ $output == *"no complete snapshot was published"* ]]
  [ ! -e "$snapshot/manifest.json" ]
  [ ! -e "$MOCK_LOG.lease" ]
  jq -e '.status == "failed" and .phase == "safely-recovered"' \
    "$snapshot/backup-state.json" > /dev/null
}

@test "unsafe backup recovery preserves the GraphQL barrier, state and Lease" {
  export MOCK_BACKUP=true MOCK_CLEANUP_FAIL=true MOCK_RECOVERY_FAIL=true
  local snapshot="$FIXTURE_ROOT/backups/snapshot-recovery-failed"

  run bash .scripts/production-k3d.sh backup "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -ne 0 ]
  [[ $output == *"GraphQL barrier and cluster Lease are retained"* ]]
  [ ! -e "$snapshot/manifest.json" ]
  [ -f "$snapshot/backup-state.json" ]
  jq -e '.status == "recovery-required" and .phase == "recovery-required"' \
    "$snapshot/backup-state.json" > /dev/null
  jq -e '.metadata.annotations["recipe-db/phase"] == "recovery-required"' \
    "$MOCK_LOG.lease" > /dev/null
  grep -q 'set env deployment/graphql MODE=backup' "$MOCK_LOG"
  grep -q 'set env deployment/graphql MODE=production' "$MOCK_LOG"
}

@test "manual backup enter status and exit preserve the durable lock and restore prior counts" {
  export MOCK_BACKUP=true
  local snapshot="$FIXTURE_ROOT/backups/manual"
  jq '(.items[] | select(.metadata.name == "tags")) |=
    (.spec.replicas=2 | .status.readyReplicas=2)' "$MOCK_LOG.deployments" > deployments.next
  mv deployments.next "$MOCK_LOG.deployments"
  run bash .scripts/production-k3d.sh backup-enter "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -eq 0 ]
  [ -f "$MOCK_LOG.lease" ]
  [ ! -e "$snapshot/manifest.json" ]
  jq -e '.status == "backup-mode" and .phase == "maintenance-entered"' "$snapshot/backup-state.json"
  run ! grep -q 'copy-pod.json' "$MOCK_LOG"
  local holder
  holder=$(jq -r .backupId "$snapshot/backup-state.json")
  run bash .scripts/production-k3d.sh backup-status "$VALUES" "$snapshot"
  [ "$status" -eq 0 ]
  [[ $output == *"$holder"* ]]
  run bash .scripts/production-k3d.sh lock-recover "$VALUES" "$holder" "RECOVER-$holder"
  [ "$status" -ne 0 ]
  [ -f "$MOCK_LOG.lease" ]
  run bash .scripts/production-k3d.sh backup-exit "$VALUES" "$snapshot" "$holder" "EXIT-$holder"
  [ "$status" -eq 0 ]
  [ ! -e "$MOCK_LOG.lease" ]
  jq -e '.status == "recovered"' "$snapshot/backup-state.json"
  jq -e '.items[] | select(.metadata.name == "tags") | .spec.replicas == 2' "$MOCK_LOG.deployments"
}

@test "forced termination prevents capture and preserves actionable recovery state" {
  export MOCK_BACKUP=true MOCK_FORCED_TERMINATION=capture
  local snapshot="$FIXTURE_ROOT/backups/forced"
  run bash .scripts/production-k3d.sh backup "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -ne 0 ]
  [[ $output == *"force-killed"* ]]
  [ -e "$MOCK_LOG.cleaned" ]
  [ ! -e "$snapshot/manifest.json" ]
  run ! grep -q 'copy-pod.json' "$MOCK_LOG"
}

@test "missing authoritative database refuses publication" {
  export MOCK_BACKUP=true
  rm "$FIXTURE_ROOT/tar-data/tags/tags.sqlite"
  local snapshot="$FIXTURE_ROOT/backups/missing"
  run bash .scripts/production-k3d.sh backup "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -ne 0 ]
  [[ $output == *"missing authoritative database"* ]]
  [ ! -e "$snapshot/manifest.json" ]
  [ ! -e "$MOCK_LOG.lease" ]
}

@test "capture measures actual archive bytes instead of trusting unenforced PVC requests" {
  export MOCK_BACKUP=true
  export MOCK_ARCHIVE_BYTES
  MOCK_ARCHIVE_BYTES=$(df -Pk "$FIXTURE_ROOT/backups" \
    | awk 'NR == 2 {printf "%.0f\n", $4 * 1024 - 67108864 + 1}')
  local snapshot="$FIXTURE_ROOT/backups/insufficient-measured-space"
  run bash .scripts/production-k3d.sh backup "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -ne 0 ]
  [[ $output == *"measured archive capacity"* ]]
  [ ! -e "$snapshot/manifest.json" ]
  [ ! -e "$MOCK_LOG.lease" ]
  run ! grep -q 'exec backup-copy-.*-- tar -C' "$MOCK_LOG"
}

@test "capture respects the publisher staging bound before copying a PVC archive" {
  export MOCK_BACKUP=true RECIPE_DB_BACKUP_MAX_SNAPSHOT_BYTES=1
  local snapshot="$FIXTURE_ROOT/backups/staging-limit"
  run bash .scripts/production-k3d.sh backup "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -ne 0 ]
  [[ $output == *"snapshot exceeds configured staging limit"* ]]
  [ ! -e "$snapshot/manifest.json" ]
  [ ! -e "$snapshot/recipes.tar" ]
  [ ! -e "$MOCK_LOG.lease" ]
  run ! grep -q 'exec backup-copy-.*-- tar -C' "$MOCK_LOG"
}

@test "projection failure retains the barrier Lease and recovery state" {
  export MOCK_BACKUP=true MOCK_PROJECTION_FAIL=true
  local snapshot="$FIXTURE_ROOT/backups/projection-failed"
  run bash .scripts/production-k3d.sh backup "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -ne 0 ]
  [[ $output == *"projection recovery failed"* ]]
  [ ! -e "$snapshot/manifest.json" ]
  [ -e "$MOCK_LOG.lease" ]
  jq -e '.status == "recovery-required"' "$snapshot/backup-state.json"
  run ! grep -q 'set env deployment/graphql MODE=production' "$MOCK_LOG"
}

@test "manual recovery refuses changed target values and holders without touching workloads" {
  export MOCK_BACKUP=true
  local snapshot="$FIXTURE_ROOT/backups/recovery-identity" holder before
  run bash .scripts/production-k3d.sh backup-enter "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -eq 0 ]
  holder=$(jq -r .backupId "$snapshot/backup-state.json")
  before=$(wc -l < "$MOCK_LOG")
  run bash .scripts/production-k3d.sh backup-exit "$VALUES" "$snapshot" wrong EXIT-wrong
  [ "$status" -ne 0 ]
  [ "$(wc -l < "$MOCK_LOG")" -eq "$before" ]
  set_value '.timeoutSeconds=601'
  run bash .scripts/production-k3d.sh backup-exit "$VALUES" "$snapshot" "$holder" "EXIT-$holder"
  [ "$status" -ne 0 ]
  [[ $output == *"original values"* ]]
  [ -e "$MOCK_LOG.lease" ]
  [ "$(wc -l < "$MOCK_LOG")" -eq "$before" ]
}

@test "projection refresh completes before the GraphQL client barrier is removed" {
  export MOCK_BACKUP=true
  local snapshot="$FIXTURE_ROOT/backups/projections"
  run bash .scripts/production-k3d.sh backup "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -eq 0 ]
  local refresh reopen
  refresh=$(awk '/rollout status deployment\/search / {line=NR} END {print line}' "$MOCK_LOG")
  reopen=$(awk '/set env deployment\/graphql MODE=production/ {print NR; exit}' "$MOCK_LOG")
  [ "$refresh" -lt "$reopen" ]
  grep -q '"targetPort":4001' "$MOCK_LOG"
  grep -q '"targetPort":4000' "$MOCK_LOG"
  jq -e '.inventory[] | select(.service == "tags") |
    any(.files[]; .path == "tags.sqlite-wal")' "$snapshot/manifest.json"
  jq -e 'all(.inventory[]; .service != "search" and .service != "browse")' "$snapshot/manifest.json"
}

@test "backup rejects image drift despite unchanged release annotations" {
  export MOCK_BACKUP=true
  jq '(.items[] | select(.metadata.name == "recipes").spec.template.spec.containers[0].image)="foreign:latest"' \
    "$MOCK_LOG.deployments" > deployments.next
  mv deployments.next "$MOCK_LOG.deployments"
  run bash .scripts/production-k3d.sh backup "$VALUES" "$ARTIFACT" "$FIXTURE_ROOT/backups/image-drift"
  [ "$status" -ne 0 ]
  [[ $output == *"container images do not match"* ]]
  [ ! -e "$MOCK_LOG.lease" ]
  run ! grep -Eq 'scale deployment/|set env deployment/' "$MOCK_LOG"
}

@test "manual recovery refuses changed container digests before touching workloads" {
  export MOCK_BACKUP=true
  local snapshot="$FIXTURE_ROOT/backups/recovery-image-drift" holder before
  run bash .scripts/production-k3d.sh backup-enter "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -eq 0 ]
  holder=$(jq -r .backupId "$snapshot/backup-state.json")
  jq '(.items[] | select(.metadata.name == "recipes").spec.template.spec.containers[0].image)="foreign:latest"' \
    "$MOCK_LOG.deployments" > deployments.next
  mv deployments.next "$MOCK_LOG.deployments"
  before=$(grep -Ec 'scale deployment/|set env deployment/' "$MOCK_LOG")
  run bash .scripts/production-k3d.sh backup-exit "$VALUES" "$snapshot" "$holder" "EXIT-$holder"
  [ "$status" -ne 0 ]
  [[ $output == *"container images do not match"* ]]
  [ -e "$MOCK_LOG.lease" ]
  [ "$(grep -Ec 'scale deployment/|set env deployment/' "$MOCK_LOG")" -eq "$before" ]
}

@test "backup refuses modified release metadata before connecting or acquiring a Lease" {
  export MOCK_BACKUP=true
  printf '\n# changed classification\n' >> .scripts/lib/project-metadata.sh
  run bash .scripts/production-k3d.sh backup "$VALUES" "$ARTIFACT" "$FIXTURE_ROOT/backups/metadata-drift"
  [ "$status" -ne 0 ]
  [[ $output == *"metadata and templates must match"* ]]
  run ! grep -Eq '^(kubectl|k3d|docker)' "$MOCK_LOG"
}

@test "backup refuses untracked metadata even if gitignored" {
  export MOCK_BACKUP=true
  mkdir extra-backend
  printf 'category: backend\n' > extra-backend/.project.yaml
  printf 'extra-backend/\n' > .gitignore
  run bash .scripts/production-k3d.sh backup "$VALUES" "$ARTIFACT" "$FIXTURE_ROOT/backups/untracked-metadata"
  [ "$status" -ne 0 ]
  [[ $output == *"untracked metadata"* ]]
  run ! grep -Eq '^(kubectl|k3d|docker)' "$MOCK_LOG"
}

@test "backup permits unrelated checkout changes when release inputs are unchanged" {
  export MOCK_BACKUP=true
  printf 'unrelated documentation\n' > note.txt
  git add note.txt
  git -c user.name=Test -c user.email=test@example.invalid commit -qm 'Unrelated checkout change'
  run bash .scripts/production-k3d.sh backup "$VALUES" "$ARTIFACT" "$FIXTURE_ROOT/backups/same-inputs"
  [ "$status" -eq 0 ]
}

@test "acquired backup Lease can be explicitly recovered before any workload mutation" {
  jq -n '{metadata:{name:"recipe-db-deploy",namespace:"kube-system",uid:"lease-uid",resourceVersion:"42",
    labels:{"app.kubernetes.io/part-of":"recipe-db"},
    annotations:{"recipe-db/operation":"backup","recipe-db/phase":"acquired"}},
    spec:{holderIdentity:"backup-preflight"}}' > "$MOCK_LOG.lease"
  run bash .scripts/production-k3d.sh lock-recover "$VALUES" backup-preflight RECOVER-backup-preflight
  [ "$status" -eq 0 ]
  [ ! -e "$MOCK_LOG.lease" ]
  run ! grep -Eq 'scale deployment/|set env deployment/' "$MOCK_LOG"
}

@test "recovered backend validation happens before GraphQL is reopened" {
  export MOCK_BACKUP=true MOCK_RECOVERY_DRIFT=true
  local snapshot="$FIXTURE_ROOT/backups/recovery-count-drift"
  run bash .scripts/production-k3d.sh backup "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -ne 0 ]
  [[ $output == *"recovered backend state could not be verified"* ]]
  [ -e "$MOCK_LOG.lease" ]
  [ ! -e "$snapshot/manifest.json" ]
  run ! grep -q 'set env deployment/graphql MODE=production' "$MOCK_LOG"
}

@test "failed GraphQL reopen and reblock rollout falls back to stopping all GraphQL Pods" {
  export MOCK_BACKUP=true MOCK_GRAPHQL_REOPEN_FAIL=true
  local snapshot="$FIXTURE_ROOT/backups/reopen-failure"
  run bash .scripts/production-k3d.sh backup "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -ne 0 ]
  [[ $output == *"stopping GraphQL to preserve the client barrier"* ]]
  [ -e "$MOCK_LOG.lease" ]
  jq -e 'any(.items[]; .metadata.name == "graphql" and .spec.replicas == 0)' "$MOCK_LOG.deployments"
  jq -e '.status == "recovery-required"' "$snapshot/backup-state.json"
}

@test "backup-exit stops cleanup workers before production backends resume" {
  export MOCK_BACKUP=true
  local snapshot="$FIXTURE_ROOT/backups/cleanup-interrupted" holder before stopped restored
  run bash .scripts/production-k3d.sh backup-enter "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -eq 0 ]
  holder=$(jq -r .backupId "$snapshot/backup-state.json")
  [ -e "$MOCK_LOG.cleanup-job" ]
  before=$(wc -l < "$MOCK_LOG")
  run bash .scripts/production-k3d.sh backup-exit "$VALUES" "$snapshot" "$holder" "EXIT-$holder"
  [ "$status" -eq 0 ]
  [ ! -e "$MOCK_LOG.cleanup-job" ]
  stopped=$(awk -v before="$before" 'NR > before && /get pods -l job-name=backup-cleanup/ {print NR; exit}' "$MOCK_LOG")
  restored=$(awk -v before="$before" 'NR > before && /set env deployment\/recipes MODE=production/ {print NR; exit}' "$MOCK_LOG")
  [ "$stopped" -lt "$restored" ]
  [ ! -e "$MOCK_LOG.lease" ]
}

@test "backup-exit retains the barrier and Lease if cleanup workers cannot be deleted" {
  export MOCK_BACKUP=true
  local snapshot="$FIXTURE_ROOT/backups/cleanup-not-stopped" holder
  run bash .scripts/production-k3d.sh backup-enter "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -eq 0 ]
  holder=$(jq -r .backupId "$snapshot/backup-state.json")
  export MOCK_CLEANUP_DELETE_FAIL=true
  run bash .scripts/production-k3d.sh backup-exit "$VALUES" "$snapshot" "$holder" "EXIT-$holder"
  [ "$status" -ne 0 ]
  [[ $output == *"cleanup workers could not be stopped"* ]]
  [ -e "$MOCK_LOG.lease" ]
  run ! grep -Eq 'set env deployment/(recipes|graphql) MODE=production' "$MOCK_LOG"
}

restore_fixture() {
  export MOCK_RESTORE=true MOCK_BACKUP=false
  export RESTORE_ID=backup-20261031123456-42
  export RESTORE_MANIFEST="$FIXTURE_ROOT/backup-package.json" RESTORE_ARCHIVE="$FIXTURE_ROOT/package.tar"
  export RESTORE_STATE="$FIXTURE_ROOT/backups/restore"
  printf '{"anonymous":{"role":"anonymous"},"tokens":[{"id":"restore-owner","secret":"private-restore-token","role":"owner"}],"googleAccounts":{}}\n' > auth-accounts.json
  rm "$FIXTURE_ROOT/tar-data/recipes/recipes.sqlite3"
  python3 - "$FIXTURE_ROOT/tar-data/recipes/recipes.sqlite3" << 'PY'
import json, sqlite3, sys
with sqlite3.connect(sys.argv[1]) as db:
    db.execute("CREATE TABLE recipes (id TEXT PRIMARY KEY, document TEXT NOT NULL)")
    db.execute("INSERT INTO recipes VALUES (?, ?)", ("old", json.dumps({"name":"Old"})))
PY
  if [[ ${MOCK_RESTORE_IMAGE:-false} == true ]]; then
    printf 'restored-full-image\n' > image-full
    printf 'restored-thumbnail\n' > image-thumb
    full_sha=$(sha256sum image-full)
    full_sha=${full_sha%% *}
    thumb_sha=$(sha256sum image-thumb)
    thumb_sha=${thumb_sha%% *}
    cp image-full "$FIXTURE_ROOT/tar-data/images/public/old-$full_sha.png"
    cp image-thumb "$FIXTURE_ROOT/tar-data/images/public/old-$thumb_sha-thumb.png"
    jq -n --arg full "/public/old-$full_sha.png" --arg thumb "/public/old-$thumb_sha-thumb.png" \
      --argjson size "$(stat -c '%s' image-full)" \
      '{recipeId:"old",url:$full,thumbUrl:$thumb,size:$size}' \
      > "$FIXTURE_ROOT/tar-data/images/manifests/old.json"
  fi
  : > restore-archives.jsonl
  for name in recipes images tags; do
    tar -C "$FIXTURE_ROOT/tar-data/$name" -cf "$FIXTURE_ROOT/$name.tar" .
    case "$name" in
      recipes) layout='{"kind":"sqlite","file":"recipes.sqlite3"}' ;;
      tags) layout='{"kind":"sqlite","file":"tags.sqlite"}' ;;
      images) layout='{"kind":"images"}' ;;
    esac
    python3 .scripts/validate-backup-snapshot.py "$FIXTURE_ROOT/$name.tar" "$layout" > "$name-files.json"
    jq -cn --arg name "$name" --slurpfile files "$name-files.json" \
      '{service:$name,archive:($name+".tar"),files:$files[0]}' >> restore-archives.jsonl
  done
  jq -n --arg id "$RESTORE_ID" --arg artifact "$ARTIFACT" --arg revision "$MOCK_REVISION" \
    --slurpfile archives restore-archives.jsonl \
    '{backupId:$id,source:{artifact:$artifact,revision:$revision},inventory:$archives}' > "$RESTORE_MANIFEST"
  printf 'package-fixture\n' > "$RESTORE_ARCHIVE"
  cat > .scripts/validate-backup-package.py << 'PY'
import json, os, pathlib, shutil, sys
if os.environ.get("MOCK_RESTORE_PACKAGE_FAIL") == "true":
    print("production: package validation failed", file=sys.stderr)
    sys.exit(1)
manifest, archive, output, projects, expected = sys.argv[1:]
package = json.loads(pathlib.Path(manifest).read_text())
assert package["backupId"] == expected
assert pathlib.Path(archive).is_file() and pathlib.Path(projects).is_file()
pathlib.Path(output).mkdir()
for item in package["inventory"]:
    shutil.copy(pathlib.Path(manifest).parent / item["archive"], pathlib.Path(output) / item["archive"])
print(json.dumps(package))
PY
  cat > bin/curl << 'EOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$MOCK_LOG"
if [[ ${MOCK_RESTORE_HTTP_FAIL:-false} == true ]]; then exit 1; fi
if [[ $* == *"api/http/routers"* ]]; then
  if [[ ${MOCK_RESTORE_ROUTE_STALE:-false} == true ]]; then
    echo '[{"name":"restore-public-barrier@file","status":"enabled"}]'
  else echo '[{"name":"graphql@file","status":"enabled"}]'; fi
  exit
fi
if [[ $* == *"/public/"* ]]; then
  url="${*: -1}"; name="${url##*/}"
  cat "$FIXTURE_ROOT/tar-data/images/public/$name"
  exit
fi
if [[ $* == *"18082"* ]]; then
  if [[ $* == *"recipe/old"* ]]; then echo Old; exit; fi
  if [[ -e $MOCK_LOG.probe-deleted ]]; then
    if [[ $* == *"--write-out"* ]]; then printf 404; exit; else exit 22; fi
  fi
  cat "$MOCK_LOG.probe-name"; exit
fi
file=
for argument in "$@"; do case "$argument" in @*) file="${argument#@}" ;; esac; done
query=$(jq -r .query "$file")
case "$query" in
  *"createRecipe"*)
    sequence=$(cat "$MOCK_LOG.stream-sequence" 2>/dev/null || echo 0)
    printf '%s\n' "$((sequence + 1))" > "$MOCK_LOG.stream-sequence"
    jq -r .variables.name "$file" > "$MOCK_LOG.probe-name"
    echo '{"data":{"createRecipe":{"id":"probe"}}}' ;;
  *"updateRecipe"*)
    sequence=$(cat "$MOCK_LOG.stream-sequence" 2>/dev/null || echo 0)
    printf '%s\n' "$((sequence + 1))" > "$MOCK_LOG.stream-sequence"
    jq -r .variables.name "$file" > "$MOCK_LOG.probe-name"
    echo '{"data":{"updateRecipe":{"id":"probe"}}}' ;;
  *"deleteRecipe"*)
    sequence=$(cat "$MOCK_LOG.stream-sequence" 2>/dev/null || echo 0)
    printf '%s\n' "$((sequence + 1))" > "$MOCK_LOG.stream-sequence"
    touch "$MOCK_LOG.probe-deleted"
    echo '{"data":{"deleteRecipe":true}}' ;;
  *"searchRecipes"*)
    if [[ ${MOCK_RESTORE_PAUSE_PROBE:-false} == true && -e $MOCK_LOG.probe-name ]]; then
      touch "$MOCK_LOG.probe-paused"
      sleep 2
    fi
    if [[ $* == *"restore-request"* && $(jq -r '.variables.options.q' "$file") == "*" ]]; then
      echo '{"data":{"searchRecipes":{"recipes":[{"id":"old","name":"Old"}],"found":1}}}'
    elif [[ -e $MOCK_LOG.probe-deleted || ${MOCK_RESTORE_PROPAGATION_FAIL:-false} == true ]]; then echo '{"data":{"searchRecipes":{"recipes":[]}}}'
    else jq -n --rawfile name "$MOCK_LOG.probe-name" '{data:{searchRecipes:{recipes:[{id:"probe",name:($name|rtrimstr("\n"))}]}}}'; fi ;;
  *"recipe(id"*)
    if [[ ${MOCK_RESTORE_IMAGE:-false} == true ]]; then
      jq '{data:{recipe:{id:"old",name:"Old",image:{url:.url,thumbUrl:.thumbUrl},rating:{count:0}}}}' \
        "$FIXTURE_ROOT/tar-data/images/manifests/old.json"
    else echo '{"data":{"recipe":{"id":"old","name":"Old","image":null,"rating":{"count":0}}}}'; fi ;;
  *) echo '{"data":{"recipes":[{"id":"old","name":"Old"}]}}' ;;
esac
EOF
  chmod +x bin/curl
}

run_restore() {
  run bash .scripts/production-k3d.sh restore "$VALUES" "$RESTORE_MANIFEST" \
    "$RESTORE_ARCHIVE" "$RESTORE_ID" "$RESTORE_STATE" "RESTORE-$RESTORE_ID"
}

restore_real_package_fixture() {
  restore_fixture
  cp "$BATS_TEST_DIRNAME/../validate-backup-package.py" .scripts/
  mkdir -p provisioning/files capture
  chmod 700 capture
  cp "$BATS_TEST_DIRNAME/../../provisioning/files/backup-upload.py" provisioning/files/
  rm "$FIXTURE_ROOT/tar-data/tags/tags.sqlite" "$FIXTURE_ROOT/tar-data/tags/tags.sqlite-wal"
  python3 - "$FIXTURE_ROOT/tar-data/tags/tags.sqlite" << 'PY'
import sqlite3, sys
with sqlite3.connect(sys.argv[1]) as database:
    database.execute("CREATE TABLE records (id TEXT PRIMARY KEY, value TEXT)")
PY
  python3 - "$FIXTURE_ROOT" "$RESTORE_ID" "$ARTIFACT" "$MOCK_REVISION" << 'PY'
import hashlib, importlib.util, json, pathlib, sys, tarfile
root, backup_id, artifact, revision = sys.argv[1:]
root = pathlib.Path(root)
spec = importlib.util.spec_from_file_location("upload", root / "provisioning/files/backup-upload.py")
upload = importlib.util.module_from_spec(spec)
spec.loader.exec_module(upload)
spec = importlib.util.spec_from_file_location("snapshot", root / ".scripts/validate-backup-snapshot.py")
snapshot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(snapshot)
inventory = []
layouts = {"recipes":{"kind":"sqlite","file":"recipes.sqlite3"},
           "tags":{"kind":"sqlite","file":"tags.sqlite"}, "images":{"kind":"images"}}
for name, layout in layouts.items():
    archive = root / "capture" / f"{name}.tar"
    with tarfile.open(archive, "w", format=tarfile.USTAR_FORMAT) as output:
        output.add(root / "tar-data" / name, arcname=".")
    archive.chmod(0o600)
    files = snapshot.validate(archive, layout)
    inventory.append({"service":name,
                      "role":"authoritative-read-only" if name == "recipes" else "cleanup-participant",
                      "pvc":name, "archive":archive.name, "sizeBytes":archive.stat().st_size,
                      "sha256":hashlib.sha256(archive.read_bytes()).hexdigest(),
                      "fileCount":len(files), "files":files})
manifest = {"format":upload.FORMAT,"formatVersion":1,"backupId":backup_id,
            "capturedAt":"2026-10-31T12:34:56Z",
            "source":{"target":"local","cluster":"recipe-db-rehearsal",
                      "context":"k3d-recipe-db-rehearsal","namespace":"recipe-db",
                      "artifact":artifact,"revision":revision},"inventory":inventory}
path = root / "capture/manifest.json"
path.write_bytes(upload.json_bytes(manifest))
path.chmod(0o600)
package = upload.create_package(root / "capture", root, manifest, "local-fixture", upload.DEFAULT_MAX_STAGING_BYTES)
(root / package["archive"]).chmod(0o600)
(root / "real-package-paths.json").write_text(json.dumps(package))
PY
  RESTORE_MANIFEST="$FIXTURE_ROOT/$(jq -r .manifest real-package-paths.json)"
  RESTORE_ARCHIVE="$FIXTURE_ROOT/$(jq -r .archive real-package-paths.json)"
}

@test "restore fully imports only after ALL volumes are empty and verifies propagation before public reopening" {
  restore_fixture
  run_restore
  [ "$status" -eq 0 ]
  [[ $output == *"verified; public ingress reopened"* ]]
  [ ! -e "$MOCK_LOG.lease" ]
  jq -e '.status == "succeeded" and .phase == "complete" and .probeRecipeId == null' \
    "$RESTORE_STATE/restore-state.json"
  [ -e "$MOCK_LOG.probe-deleted" ]
  cmp "$FIXTURE_ROOT/tar-data/recipes/recipes.sqlite3" "$FIXTURE_ROOT/imported/recipes/recipes.sqlite3"
  local checked imported last_check propagation opening
  checked=$(grep -c 'exec restore-volume-.*-- sh -ec' "$MOCK_LOG")
  [ "$checked" -ge 11 ]
  imported=$(awk '/exec -i restore-volume-.*tar -xpkf/ {print NR; exit}' "$MOCK_LOG")
  last_check=$(awk '/exec restore-volume-typesense -- sh -ec/ {print NR; exit}' "$MOCK_LOG")
  [ "$last_check" -lt "$imported" ]
  propagation=$(awk '/recipe\/probe/ {n=NR} END {print n}' "$MOCK_LOG")
  opening=$(awk '/from-file=routes.yml=.*restore-final-routes/ {print NR; exit}' "$MOCK_LOG")
  [ "$propagation" -lt "$opening" ]
  jq -e '.http.routers["restore-public-barrier"] == null' "$MOCK_LOG.restore-routes"
  jq -e 'any(.items[]; .metadata.name == "browse" and
    any(.spec.template.spec.containers[].env[]; .name == "GRAPHQL_URL"
      and .value == "http://traefik:3000/graphql"))' "$MOCK_LOG.restore-deployments"
  run ! grep -q private-restore-token "$MOCK_LOG"
}

@test "restore validates package and runtime secrets before connecting or taking shared Lease" {
  restore_fixture
  export MOCK_RESTORE_PACKAGE_FAIL=true
  run_restore
  [ "$status" -ne 0 ]
  [[ $output == *"package validation failed"* ]]
  run ! grep -Eq '^(kubectl|k3d|docker)' "$MOCK_LOG"
  [ ! -e "$RESTORE_STATE" ]
  export MOCK_RESTORE_PACKAGE_FAIL=false
  rm graphql-ingress-secret
  run_restore
  [ "$status" -ne 0 ]
  run ! grep -Eq '^(kubectl|k3d|docker)' "$MOCK_LOG"
}

@test "restore identity confirmation and symlink inputs fail without mutation" {
  restore_fixture
  run bash .scripts/production-k3d.sh restore "$VALUES" "$RESTORE_MANIFEST" \
    "$RESTORE_ARCHIVE" "$RESTORE_ID" "$RESTORE_STATE" RESTORE-wrong
  [ "$status" -ne 0 ]
  run ! grep -Eq '^(kubectl|k3d|docker)' "$MOCK_LOG"
  ln -s "$RESTORE_ARCHIVE" package-link.tar
  run bash .scripts/production-k3d.sh restore "$VALUES" "$RESTORE_MANIFEST" \
    "$FIXTURE_ROOT/package-link.tar" "$RESTORE_ID" "$RESTORE_STATE" "RESTORE-$RESTORE_ID"
  [ "$status" -ne 0 ]
  [[ $output == *"without symlink traversal"* ]]
}

@test "restore refuses populated authoritative derived and external cache volumes without any import" {
  restore_fixture
  for name in recipes nats redis; do
    export MOCK_RESTORE_NONEMPTY="$name"
    RESTORE_STATE="$FIXTURE_ROOT/backups/nonempty-$name"
    run_restore
    [ "$status" -ne 0 ]
    [[ $output == *"populated; NOTHING will be wiped"* ]]
    jq -e '.status == "recovery-required"' "$RESTORE_STATE/restore-state.json"
    [ -e "$MOCK_LOG.lease" ]
    run ! grep -Eq 'tar -xpk?f|delete pvc|delete pv|rm -rf /data' "$MOCK_LOG"
    rm "$MOCK_LOG.lease" "$MOCK_LOG.claims" "$MOCK_LOG.restore-pods" "$MOCK_LOG.cluster-restore-state"
    : > "$MOCK_LOG"
  done
}

@test "restore fails closed when the destination volume scan fails" {
  restore_fixture
  export MOCK_RESTORE_FIND_FAIL=true
  run_restore
  [ "$status" -ne 0 ]
  [[ $output == *"populated; NOTHING will be wiped"* ]]
  [ ! -e "$MOCK_LOG.imported" ]
  run ! grep -q 'exec -i restore-volume-' "$MOCK_LOG"
}

@test "restore shares kube-system Lease with deploy and backup and never steals a busy holder" {
  restore_fixture
  export MOCK_LOCK=true
  run_restore
  [ "$status" -ne 0 ]
  [[ $output == *"cluster operation lock"* ]]
  [ ! -e "$RESTORE_STATE" ]
  grep -q -- '--namespace kube-system.*create -f .*recipe-db-deploy-lease.json' "$MOCK_LOG"
  run ! grep -Eq 'restore-volume-pod.json|apply -f .*application.yml|delete --raw' "$MOCK_LOG"
}

@test "restore refuses an existing deployment or released retained data without replacing it" {
  restore_fixture
  export MOCK_RESTORE_EXISTING=true
  run_restore
  [ "$status" -ne 0 ]
  [[ $output == *"fresh deployment"* ]]
  [ ! -e "$RESTORE_STATE" ]
  run ! grep -Eq 'restore-volume-pod.json|apply -f .*application.yml' "$MOCK_LOG"
  export MOCK_RESTORE_EXISTING=false MOCK_RESTORE_RELEASED=true
  run_restore
  [ "$status" -ne 0 ]
  [[ $output == *"released or unbound retained"* ]]
}

@test "restore import or verification failures retain durable barrier Lease and explicit recovery state" {
  restore_fixture
  export MOCK_RESTORE_IMPORT_FAIL=true
  run_restore
  [ "$status" -ne 0 ]
  [[ $output == *"restore FAILED; no success recorded"* ]]
  [ -e "$MOCK_LOG.lease" ]
  jq -e '.status == "recovery-required" and (.phase | startswith("import-"))' \
    "$RESTORE_STATE/restore-state.json"
  jq -e '.http.routers["restore-public-barrier"].entrypoints == ["web"]' "$MOCK_LOG.restore-routes"
  run ! grep -q 'restore-final-routes' "$MOCK_LOG"
}

@test "restore failed representative reads never reopen public ingress" {
  restore_fixture
  export MOCK_RESTORE_HTTP_FAIL=true
  run_restore
  [ "$status" -ne 0 ]
  [ -e "$MOCK_LOG.lease" ]
  jq -e '.status == "recovery-required" and .phase == "verifying-reads"' "$RESTORE_STATE/restore-state.json"
  run ! grep -q 'from-file=routes.yml=.*restore-final-routes' "$MOCK_LOG"
  jq -e '.http.routers["restore-public-barrier"] != null' "$MOCK_LOG.restore-routes"
}

@test "restore verifies restored full image and thumbnail bytes only on the private static ingress" {
  export MOCK_RESTORE_IMAGE=true
  restore_fixture
  run_restore
  [ "$status" -eq 0 ]
  [ "$(grep -c 'curl .*18081/public/old-' "$MOCK_LOG")" -eq 4 ]
  jq -e '.status == "succeeded"' "$RESTORE_STATE/restore-state.json"
}

@test "restore propagation failure records its synthetic recipe and keeps public ingress blocked" {
  restore_fixture
  set_value '.timeoutSeconds=3'
  export MOCK_RESTORE_PROPAGATION_FAIL=true
  run_restore
  [ "$status" -ne 0 ]
  [ -e "$MOCK_LOG.lease" ]
  jq -e '.status == "recovery-required" and .phase == "verifying-propagation"
    and .probeRecipeId == "probe"' "$RESTORE_STATE/restore-state.json"
  run ! grep -q 'from-file=routes.yml=.*restore-final-routes' "$MOCK_LOG"
}

@test "restore waits for actual Traefik route convergence and reblocks a failed cutover" {
  restore_fixture
  set_value '.timeoutSeconds=3'
  export MOCK_RESTORE_ROUTE_STALE=true
  run_restore
  [ "$status" -ne 0 ]
  [[ $output != *"verified; public ingress reopened"* ]]
  [ -e "$MOCK_LOG.lease" ]
  jq -e '.status == "recovery-required" and .phase == "opening-public-ingress"' \
    "$RESTORE_STATE/restore-state.json"
  jq -e '.http.routers["restore-public-barrier"] != null' "$MOCK_LOG.restore-routes"
}

@test "restore loses shared Lease ownership mid-import without deleting another holder or opening clients" {
  restore_fixture
  export MOCK_RESTORE_LOCK_DRIFT=true
  run_restore
  [ "$status" -ne 0 ]
  [ -e "$MOCK_LOG.lease" ]
  jq -e '.status == "recovery-required"' "$RESTORE_STATE/restore-state.json"
  run ! grep -Eq 'delete --raw|restore-final-routes' "$MOCK_LOG"
}

@test "restore rejects changed release inputs and missing owner token before connecting" {
  restore_fixture
  printf '# changed release metadata\n' >> .scripts/lib/project-metadata.sh
  run_restore
  [ "$status" -ne 0 ]
  [[ $output == *"must match the immutable release"* ]]
  run ! grep -Eq '^(kubectl|k3d|docker)' "$MOCK_LOG"
  git checkout -- .scripts/lib/project-metadata.sh
  printf '{"anonymous":{"role":"anonymous"},"tokens":[],"googleAccounts":{}}\n' > auth-accounts.json
  run_restore
  [ "$status" -ne 0 ]
  [[ $output == *"explicit owner token"* ]]
  run ! grep -Eq '^(kubectl|k3d|docker)' "$MOCK_LOG"
}

@test "restore rejects modified routing templates before connecting" {
  restore_fixture
  local template
  for template in \
    .scripts/templates/traefik-template.yml \
    .scripts/templates/browse-maintenance-template.lib.yml \
    .scripts/templates/service-template.lib.yml; do
    printf 'release route template\n' > "$template"
  done
  git add .scripts/templates
  git -c user.name=Test -c user.email=test@example.invalid commit -qm 'Fixture route templates'
  MOCK_REVISION=$(git rev-parse HEAD)
  export MOCK_REVISION
  jq --arg revision "$MOCK_REVISION" '.source.revision=$revision' "$RESTORE_MANIFEST" \
    > "$RESTORE_MANIFEST.next"
  mv "$RESTORE_MANIFEST.next" "$RESTORE_MANIFEST"
  for template in \
    .scripts/templates/traefik-template.yml \
    .scripts/templates/browse-maintenance-template.lib.yml \
    .scripts/templates/service-template.lib.yml; do
    printf 'modified route template\n' >> "$template"
    run_restore
    [ "$status" -ne 0 ]
    [[ $output == *"must match the immutable release"* ]]
    git checkout -- "$template"
  done
  run ! grep -Eq '^(kubectl|k3d|docker)' "$MOCK_LOG"
}

@test "restore refuses untracked routing templates before connecting" {
  restore_fixture
  printf 'untracked route template\n' > .scripts/templates/traefik-template.yml
  printf 'untracked route template\n' > .scripts/templates/browse-maintenance-template.lib.yml
  printf 'untracked route template\n' > .scripts/templates/service-template.lib.yml
  run_restore
  [ "$status" -ne 0 ]
  [[ $output == *"untracked metadata or template inputs"* ]]
  run ! grep -Eq '^(kubectl|k3d|docker)' "$MOCK_LOG"
}

restore_retained_fixture() {
  restore_fixture
  export RESTORE_HOLDER=restore-retained-42
  mkdir -p "$RESTORE_STATE"
  jq -n --arg holder "$RESTORE_HOLDER" --arg artifact "$ARTIFACT" \
    --arg sha "$(sha256sum "$VALUES" | cut -d ' ' -f 1)" --slurpfile config "$VALUES" '
    {version:1,holder:$holder,status:"recovery-required",artifact:$artifact,
      target:$config[0].target,cluster:$config[0].cluster,context:$config[0].context,
      namespace:$config[0].namespace,configSha256:$sha}' > "$RESTORE_STATE/restore-state.json"
  # production_config serializes with jq, so hash that same canonical representation.
  jq '.' "$VALUES" > canonical-values.json
  sha=$(sha256sum canonical-values.json)
  sha=${sha%% *}
  jq --arg sha "$sha" '.configSha256=$sha' "$RESTORE_STATE/restore-state.json" > state.next
  mv state.next "$RESTORE_STATE/restore-state.json"
  jq -n --arg holder "$RESTORE_HOLDER" --arg artifact "$ARTIFACT" '
    {metadata:{name:"recipe-db-deploy",namespace:"kube-system",uid:"lease-uid",resourceVersion:"42",
      labels:{"app.kubernetes.io/part-of":"recipe-db"},
      annotations:{"recipe-db/operation":"restore","recipe-db/phase":"restore-import-recipes",
        "recipe-db/release":$artifact}},spec:{holderIdentity:$holder}}' > "$MOCK_LOG.lease"
  jq -n '{http:{routers:{"restore-public-barrier":{entrypoints:["web"],service:"restore-maintenance"}},
    services:{"restore-maintenance":{loadBalancer:{servers:[
      {url:"http://browse-maintenance.recipe-db.svc.cluster.local:80"}]}}}}}' > "$MOCK_LOG.restore-routes"
}

run_restore_abandon() {
  run bash .scripts/production-k3d.sh restore-abandon "$VALUES" "$RESTORE_STATE" \
    "$RESTORE_HOLDER" "ABANDON-$RESTORE_HOLDER-AFTER-ISOLATION"
}

@test "restore acquired Lease alone can recover but post-mutation Lease cannot use unconditional lock-recover" {
  restore_retained_fixture
  run bash .scripts/production-k3d.sh lock-recover "$VALUES" "$RESTORE_HOLDER" "RECOVER-$RESTORE_HOLDER"
  [ "$status" -ne 0 ]
  [[ $output == *"restore-abandon with saved state"* ]]
  [ -e "$MOCK_LOG.lease" ]
  jq '.metadata.annotations["recipe-db/phase"]="acquired"' "$MOCK_LOG.lease" > lease.next
  mv lease.next "$MOCK_LOG.lease"
  run bash .scripts/production-k3d.sh lock-recover "$VALUES" "$RESTORE_HOLDER" "RECOVER-$RESTORE_HOLDER"
  [ "$status" -eq 0 ]
  [ ! -e "$MOCK_LOG.lease" ]
}

@test "restore abandonment releases only an investigated isolated target while preserving data and public barrier" {
  restore_retained_fixture
  printf 'partial authoritative data\n' > partial-data
  run_restore_abandon
  [ "$status" -eq 0 ]
  [[ $output == *"data and public barrier preserved"* ]]
  [ ! -e "$MOCK_LOG.lease" ]
  [ "$(cat partial-data)" = "partial authoritative data" ]
  jq -e '.status == "abandoned" and .phase == "isolated-new-target-required"' \
    "$RESTORE_STATE/restore-state.json"
  jq -e '.http.routers["restore-public-barrier"] != null' "$MOCK_LOG.restore-routes"
  run ! grep -Eq 'tar -xpk?f|delete pvc|delete pv|scale deployment|set env deployment' "$MOCK_LOG"
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  [[ $output == *"unresolved or abandoned restore state"* ]]
}

@test "restore abandonment rejects active writers helper Pods restartable Jobs and a missing public barrier" {
  restore_retained_fixture
  for flag in MOCK_ABANDON_WRITER MOCK_ABANDON_WORKER MOCK_ABANDON_JOB MOCK_ABANDON_BAD_BARRIER; do
    export "$flag=true"
    run_restore_abandon
    [ "$status" -ne 0 ]
    [ -e "$MOCK_LOG.lease" ]
    jq -e '.status == "recovery-required"' "$RESTORE_STATE/restore-state.json"
    unset "$flag"
  done
  run ! grep -q 'delete --raw' "$MOCK_LOG"
}

@test "restore abandonment rejects wrong confirmation holder and changed target values before connecting" {
  restore_retained_fixture
  run bash .scripts/production-k3d.sh restore-abandon "$VALUES" "$RESTORE_STATE" \
    "$RESTORE_HOLDER" "RECOVER-$RESTORE_HOLDER"
  [ "$status" -ne 0 ]
  run bash .scripts/production-k3d.sh restore-abandon "$VALUES" "$RESTORE_STATE" \
    wrong-holder ABANDON-wrong-holder-AFTER-ISOLATION
  [ "$status" -ne 0 ]
  set_value '.timeoutSeconds=599'
  run_restore_abandon
  [ "$status" -ne 0 ]
  [[ $output == *"state, target values or holder mismatch"* ]]
  run ! grep -Eq '^(kubectl|k3d|docker)' "$MOCK_LOG"
  [ -e "$MOCK_LOG.lease" ]
}

@test "restore completed state permits later ordinary immutable deployment" {
  restore_fixture
  run_restore
  [ "$status" -eq 0 ]
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  [ ! -e "$MOCK_LOG.lease" ]
}

@test "restore full CLI consumes a real packaged SQLite snapshot through the real validator with mocked cluster infrastructure" {
  restore_real_package_fixture
  run_restore
  [ "$status" -eq 0 ]
  jq -e '.status == "succeeded" and .phase == "complete"' "$RESTORE_STATE/restore-state.json"
  [ ! -e "$MOCK_LOG.lease" ]
  [ -e "$MOCK_LOG.probe-deleted" ]
  cmp "$FIXTURE_ROOT/tar-data/tags/tags.sqlite" "$FIXTURE_ROOT/imported/tags/tags.sqlite"
}

@test "restore SIGTERM during private synthetic propagation retains the public barrier Lease and recovery state" {
  restore_fixture
  export MOCK_RESTORE_PAUSE_PROBE=true
  bash .scripts/production-k3d.sh restore "$VALUES" "$RESTORE_MANIFEST" "$RESTORE_ARCHIVE" \
    "$RESTORE_ID" "$RESTORE_STATE" "RESTORE-$RESTORE_ID" > term-output 2>&1 &
  local pid=$! deadline=$((SECONDS + 20)) result
  while [[ ! -e $MOCK_LOG.probe-paused ]]; do
    if ! kill -0 "$pid" 2> /dev/null || ((SECONDS >= deadline)); then
      kill "$pid" 2> /dev/null || true
      wait "$pid" 2> /dev/null || true
      cat term-output
      return 1
    fi
    sleep 0.1
  done
  jq -e '.http.routers["restore-public-barrier"].entrypoints == ["web"]
    and .http.routers["graphql-internal"].entrypoints == ["rest-internal"]' "$MOCK_LOG.restore-routes"
  kill -TERM "$pid"
  if wait "$pid"; then result=0; else result=$?; fi
  [ "$result" -eq 143 ]
  [ -e "$MOCK_LOG.lease" ]
  jq -e '.status == "recovery-required" and .phase == "verifying-propagation"
    and .probeRecipeId == "probe"' "$RESTORE_STATE/restore-state.json"
  jq -e '.http.routers["restore-public-barrier"].entrypoints == ["web"]' "$MOCK_LOG.restore-routes"
  jq -e 'any(.items[]; .metadata.name == "graphql" and
    any(.spec.template.spec.containers[].env[]; .name == "MODE" and .value == "backup"))' \
    "$MOCK_LOG.restore-deployments"
  run ! grep -q 'from-file=routes.yml=.*restore-final-routes' "$MOCK_LOG"
}
