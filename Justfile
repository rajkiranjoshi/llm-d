set dotenv-load
set dotenv-required

NAMESPACE := env("NAMESPACE", env("USER", "dev") + "-dev")
HF_TOKEN := "$HF_TOKEN"

KN := "kubectl -n " + NAMESPACE
PD_DIR := "guides/pd-disaggregation"

default:
  just --list

# --- Cluster Info ---

# Show GPU allocation across all nodes
@print-gpus:
  kubectl get pods -A -o json | jq -r ' \
    .items \
    | map(select(.status.phase=="Running")) \
    | map({ \
        ns: .metadata.namespace, \
        pod: .metadata.name, \
        node: .spec.nodeName, \
        gpus: ([ .spec.containers[]? \
          | ( (.resources.limits."nvidia.com/gpu" \
              // .resources.requests."nvidia.com/gpu" \
              // "0" | tonumber) ) ] | add) \
      }) \
    | map(select(.gpus>0 and .node != null)) \
    | sort_by(.node, .ns, .pod) \
    | group_by(.node) \
    | .[] as $grp \
    | "== Node: \($grp[0].node) ==", \
      "NAMESPACE\tPOD\tGPUs", \
      ( $grp[] | "\(.ns)\t\(.pod)\t\(.gpus)" ), \
      "" \
    ' | column -t -s $'\t' \
    | awk 'NR==1{print; next} /^== /{print ""; print; next} {print}'

# Check InfiniBand port health on GPU nodes
check-ib:
  kubectl get pods -n network-operator -l app.kubernetes.io/name=doca-telemetry -o wide
  @echo ""
  @echo "IB Port States (4=Active):"
  kubectl -n llm-d-monitoring exec prometheus-llmd-kube-prometheus-stack-prometheus-0 -c prometheus -- \
    wget -qO- --no-check-certificate 'https://localhost:9090/api/v1/query?query=ib_port_state{hca=~"mlx5_[0-7]"}' 2>/dev/null \
    | python3 -c "import sys,json; [print(f'  {r[\"metric\"][\"source\"]} / {r[\"metric\"][\"hca\"]} = state {r[\"value\"][1]}') for r in sorted(json.load(sys.stdin)['data']['result'], key=lambda x: (x['metric']['source'], x['metric']['hca']))]"

# --- Namespace Setup ---

# Create the deployment namespace with secrets
setup:
  kubectl create ns {{NAMESPACE}} --dry-run=client -o yaml | kubectl apply -f -
  kubectl label --overwrite ns {{NAMESPACE}} pod-security.kubernetes.io/enforce=privileged
  kubectl create secret generic hf-secret \
    --from-literal=HF_TOKEN={{HF_TOKEN}} -n {{NAMESPACE}} \
    --dry-run=client -o yaml | kubectl apply -f -

# --- P/D Disaggregation ---

# Deploy P/D disaggregated stack on AKS (uses guides/pd-disaggregation)
deploy:
  cd {{PD_DIR}} && helmfile apply -e aks -n {{NAMESPACE}}
  {{KN}} apply -f {{PD_DIR}}/httproute.yaml

# Tear down the P/D deployment
destroy:
  cd {{PD_DIR}} && helmfile destroy -n {{NAMESPACE}}
  {{KN}} delete -f {{PD_DIR}}/httproute.yaml --ignore-not-found=true

# Show pod status
status:
  {{KN}} get pods -o wide
  @echo ""
  {{KN}} get inferencepool,inferencemodel 2>/dev/null || true

# Show Helm releases
releases:
  helm list -n {{NAMESPACE}}

# Wait for all pods to be ready
ready:
  #!/usr/bin/env bash
  set -euo pipefail
  echo "Waiting for decode pods..."
  {{KN}} wait --for=condition=Ready pod -l llm-d.ai/role=decode --timeout=1200s &
  echo "Waiting for prefill pods..."
  ({{KN}} wait --for=condition=Ready pod -l llm-d.ai/role=prefill --timeout=1200s 2>/dev/null || true) &
  echo "Waiting for EPP pod..."
  {{KN}} wait --for=condition=Ready pod -l app.kubernetes.io/name=inferencepool-epp --timeout=120s &
  wait
  echo "All pods ready."

# Restart model server pods (force-delete, then redeploy)
restart:
  #!/usr/bin/env bash
  set -euo pipefail
  {{KN}} delete pod -l llm-d.ai/role=decode --grace-period=0 --force --ignore-not-found=true &
  {{KN}} delete pod -l llm-d.ai/role=prefill --grace-period=0 --force --ignore-not-found=true &
  wait
  just deploy

# Follow logs from decode or prefill pods
logs ROLE='decode':
  {{KN}} logs -l llm-d.ai/role={{ROLE}} -c vllm --tail=100 -f --max-log-requests=10

# --- Benchmarking ---

# Deploy the poker pod for interactive benchmarking
start-poker:
  {{KN}} apply -f poker/poker.yaml

# Exec into the poker pod
poke:
  #!/usr/bin/env bash
  set -euo pipefail
  GATEWAY_SVC=$({{KN}} get svc -l gateway.networking.k8s.io/gateway-name -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -z "$GATEWAY_SVC" ]; then
    echo "Error: no gateway service found in {{NAMESPACE}}" >&2
    exit 1
  fi
  export BASE_URL="http://${GATEWAY_SVC}.{{NAMESPACE}}.svc.cluster.local"
  echo "BASE_URL=$BASE_URL"
  {{KN}} exec -it poker -- /bin/bash

# Stop the poker pod
stop-poker:
  {{KN}} delete pod poker --ignore-not-found=true

# --- Port Forwards ---

# Port-forward Grafana to localhost:3000
grafana:
  kubectl port-forward -n llm-d-monitoring svc/llmd-grafana 3000:80 > /dev/null 2>&1 &
  @echo "Grafana available at http://localhost:3000 (admin/admin)"

# Port-forward Prometheus to localhost:9090
prometheus:
  kubectl port-forward -n llm-d-monitoring svc/llmd-kube-prometheus-stack-prometheus 9090:9090 > /dev/null 2>&1 &
  @echo "Prometheus available at https://localhost:9090"
