#!/bin/bash
set -e

echo "========================================="
echo "  Microservices K8s - Setup Script"
echo "========================================="

# ─── Check prerequisites ───
echo ""
echo "[1/6] Checking prerequisites..."

if ! command -v docker &> /dev/null; then
  echo "ERROR: Docker is not installed. Install Docker Desktop first."
  exit 1
fi

if ! command -v kubectl &> /dev/null; then
  echo "ERROR: kubectl is not installed. Run: brew install kubectl"
  exit 1
fi

if ! kubectl cluster-info &> /dev/null; then
  echo "ERROR: No Kubernetes cluster running."
  echo "  → Enable Kubernetes in Docker Desktop: Settings > Kubernetes > Enable"
  exit 1
fi

echo "  Docker: OK"
echo "  kubectl: OK"
echo "  Cluster: OK"

# ─── Build Docker images ───
echo ""
echo "[2/6] Building Docker images..."

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

docker build -t api:latest "$PROJECT_DIR/services/api/"
docker build -t web:latest "$PROJECT_DIR/services/web/"

echo "  Images built successfully."

# ─── Deploy dev environment ───
echo ""
echo "[3/6] Deploying dev environment..."

kubectl apply -k "$PROJECT_DIR/k8s/overlays/dev"

echo "  Waiting for pods to be ready..."
kubectl wait --for=condition=available deployment/postgres -n demo-dev --timeout=120s 2>/dev/null || true
kubectl wait --for=condition=available deployment/api -n demo-dev --timeout=120s 2>/dev/null || true
kubectl wait --for=condition=available deployment/web -n demo-dev --timeout=120s 2>/dev/null || true

# ─── Install ArgoCD ───
echo ""
echo "[4/6] Installing ArgoCD..."

kubectl create namespace argocd 2>/dev/null || true
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "  Waiting for ArgoCD server to be ready..."
kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=300s

# ─── Apply ArgoCD configs ───
echo ""
echo "[5/6] Applying ArgoCD application configs..."

kubectl apply -f "$PROJECT_DIR/argocd/project.yaml"
kubectl apply -f "$PROJECT_DIR/argocd/app-dev.yaml"
kubectl apply -f "$PROJECT_DIR/argocd/app-staging.yaml"
kubectl apply -f "$PROJECT_DIR/argocd/app-prod.yaml"

# ─── Print status ───
echo ""
echo "[6/6] Setup complete!"
echo ""
echo "========================================="
echo "  Status"
echo "========================================="
echo ""

echo "Pods:"
kubectl get pods -n demo-dev 2>/dev/null || true
echo ""

ARGO_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "not available yet")

echo "========================================="
echo "  Access"
echo "========================================="
echo ""
echo "  App:     kubectl port-forward svc/web 3000:80 -n demo-dev"
echo "           → http://localhost:3000"
echo ""
echo "  ArgoCD:  kubectl port-forward svc/argocd-server 8443:443 -n argocd"
echo "           → https://localhost:8443"
echo "           User: admin"
echo "           Pass: $ARGO_PASS"
echo ""
echo "========================================="
