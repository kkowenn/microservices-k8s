#!/bin/bash
set -euo pipefail

# Pause/resume the existing Kind cluster without deleting containers or volumes.
ACTION="${1:-stop}"
CLUSTER="${KIND_CLUSTER_NAME:-kind}"
CONTEXT="kind-$CLUSTER"

case "$ACTION" in
  stop|start) ;;
  *)
    echo "Usage: bash scripts/local-cluster.sh [stop|start]" >&2
    exit 1
    ;;
esac

command -v docker >/dev/null || { echo "ERROR: Docker is required." >&2; exit 1; }
docker info >/dev/null

# Match Kind's cluster label so unrelated Docker containers are untouched.
NODES=()
while IFS= read -r node; do
  if [ -n "$node" ]; then
    NODES+=("$node")
  fi
done < <(docker ps -a --filter "label=io.x-k8s.kind.cluster=$CLUSTER" --format '{{.Names}}')

if [ "${#NODES[@]}" -eq 0 ]; then
  echo "No Docker-backed Kind cluster named '$CLUSTER' was found." >&2
  exit 1
fi

if [ "$ACTION" = stop ]; then
  # Stop kubectl forwards/proxies explicitly targeting this cluster.
  # The process-name check avoids matching shells containing kubectl text.
  while IFS= read -r forward_pid; do
    if [ -n "$forward_pid" ]; then
      echo "Stopping local forwarding process $forward_pid"
      kill -TERM "$forward_pid" 2>/dev/null || true
    fi
  done < <(ps -axo pid=,command= | awk -v context="$CONTEXT" '
    $2 ~ /(^|\/)kubectl$/ {
      target = 0
      forwarding = 0
      for (i = 3; i <= NF; i++) {
        if ($i == "--context=" context) target = 1
        if ($i == "--context" && $(i + 1) == context) target = 1
        if ($i == "port-forward" || $i == "proxy") forwarding = 1
      }
      if (target && forwarding) print $1
    }
  ')

  docker stop --timeout 60 "${NODES[@]}"
  echo "Kind cluster '$CLUSTER' stopped. Containers and stored data are preserved."
  echo "Resume with: KIND_CLUSTER_NAME=$CLUSTER bash scripts/local-cluster.sh start"
else
  docker start "${NODES[@]}"
  if command -v kubectl >/dev/null; then
    echo "Waiting for the Kubernetes API and nodes..."
    api_ready=false
    for attempt in {1..30}; do
      if kubectl --context="$CONTEXT" --request-timeout=5s get nodes >/dev/null 2>&1; then
        api_ready=true
        break
      fi
      sleep 2
    done
    if [ "$api_ready" != true ]; then
      echo "Containers started, but Kubernetes is not ready yet. Check Docker and node logs." >&2
      exit 1
    fi
    kubectl --context="$CONTEXT" wait --for=condition=Ready nodes --all --timeout=180s
    kubectl --context="$CONTEXT" -n demo-dev get pods
  fi
  echo "Open the app after its pods are ready:"
  echo "kubectl --context=$CONTEXT -n demo-dev port-forward svc/nginx 3000:80"
fi
