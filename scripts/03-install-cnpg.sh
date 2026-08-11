#!/bin/bash
set -e

echo "========================================="
echo "  Microservices K8s - Install CNPG"
echo "========================================="

# ─── Check prerequisites ───
echo ""
echo "[1/3] Checking prerequisites..."

if ! command -v kubectl &> /dev/null; then
  echo "ERROR: kubectl is not installed."
  exit 1
fi

if ! kubectl cluster-info &> /dev/null; then
  echo "ERROR: No Kubernetes cluster running."
  exit 1
fi

echo "  kubectl: OK"
echo "  Cluster: OK"

# ─── Install CNPG operator ───
echo ""
echo "[2/3] Installing CloudNativePG operator..."

kubectl apply --server-side -f \
  https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.25/releases/cnpg-1.25.1.yaml

echo ""
echo "  Waiting for CNPG operator to be ready..."
kubectl wait --for=condition=available deployment/cnpg-controller-manager \
  -n cnpg-system --timeout=120s

echo "  CNPG operator installed."

# ─── Deploy dev-cnpg environment ───
echo ""
echo "[3/3] Deploying dev-cnpg environment..."

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

kubectl apply -k "$PROJECT_DIR/k8s/overlays/dev-cnpg"

echo ""
echo "========================================="
echo "  CNPG Setup Complete"
echo "========================================="
echo ""
echo "  Check CNPG cluster status:"
echo "    kubectl get cluster -n demo-dev"
echo "    kubectl describe cluster cnpg-cluster -n demo-dev"
echo ""
echo "  Check pods:"
echo "    kubectl get pods -n demo-dev"
echo ""
echo "  The CNPG auto-generated secret:"
echo "    kubectl get secret cnpg-cluster-app -n demo-dev -o yaml"
echo ""
echo "========================================="
