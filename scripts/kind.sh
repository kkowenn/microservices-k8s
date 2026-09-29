#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER="${KIND_CLUSTER_NAME:-kind}"
CONTEXT="kind-$CLUSTER"
NAMESPACE="demo-dev"

for tool in docker kind kubectl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: $tool is required." >&2
    exit 1
  fi
done
docker info >/dev/null
kubectl --context="$CONTEXT" cluster-info

# Share the local overlay and image tags with the Minikube setup.
docker build -t api:local "$PROJECT_DIR/services/api"
docker build -t web:local "$PROJECT_DIR/services/web"
kind load docker-image --name "$CLUSTER" api:local web:local

kubectl --context="$CONTEXT" apply -k "$PROJECT_DIR/k8s/overlays/local"
kubectl --context="$CONTEXT" -n "$NAMESPACE" rollout restart deployment/api deployment/web
kubectl --context="$CONTEXT" -n "$NAMESPACE" rollout status statefulset/postgres --timeout=300s
for deployment in api web nginx; do
  kubectl --context="$CONTEXT" -n "$NAMESPACE" rollout status "deployment/$deployment" --timeout=300s
done
kubectl --context="$CONTEXT" -n "$NAMESPACE" get pods

echo ""
echo "Run this command and keep it running to access http://localhost:3000:"
echo "kubectl --context=$CONTEXT -n $NAMESPACE port-forward svc/nginx 3000:80"
