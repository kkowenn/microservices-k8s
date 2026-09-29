#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="microservices-k8s"
NAMESPACE="demo-dev"

for tool in docker minikube kubectl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: $tool is required." >&2
    exit 1
  fi
done
docker info >/dev/null

minikube start -p "$PROFILE" --driver=docker --cpus=2 --memory=3072 --keep-context
docker build -t api:local "$PROJECT_DIR/services/api"
docker build -t web:local "$PROJECT_DIR/services/web"
minikube -p "$PROFILE" image load --overwrite=true api:local web:local

kubectl --context="$PROFILE" apply -k "$PROJECT_DIR/k8s/overlays/local"
# Recreate app pods so repeat runs use the freshly built local images.
kubectl --context="$PROFILE" -n "$NAMESPACE" rollout restart deployment/api deployment/web
kubectl --context="$PROFILE" -n "$NAMESPACE" rollout status statefulset/postgres --timeout=300s
for deployment in api web nginx; do
  kubectl --context="$PROFILE" -n "$NAMESPACE" rollout status "deployment/$deployment" --timeout=300s
done
kubectl --context="$PROFILE" -n "$NAMESPACE" get pods

echo ""
echo "Run this command and keep it running to access http://localhost:3000:"
echo "kubectl --context=$PROFILE -n $NAMESPACE port-forward svc/nginx 3000:80"
echo "Stop the cluster: minikube stop -p $PROFILE"
