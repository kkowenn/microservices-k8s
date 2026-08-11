#!/bin/bash
set -e

echo "========================================="
echo "  Microservices K8s - Cleanup Script"
echo "========================================="
echo ""

# ─── Confirm ───
read -p "This will delete all demo resources. Continue? (y/N): " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
  echo "Cancelled."
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# ─── Remove ArgoCD apps ───
echo ""
echo "[1/4] Removing ArgoCD applications..."

kubectl delete -f "$PROJECT_DIR/argocd/app-dev.yaml" 2>/dev/null || true
kubectl delete -f "$PROJECT_DIR/argocd/app-staging.yaml" 2>/dev/null || true
kubectl delete -f "$PROJECT_DIR/argocd/app-prod.yaml" 2>/dev/null || true
kubectl delete -f "$PROJECT_DIR/argocd/project.yaml" 2>/dev/null || true

# ─── Remove demo environments ───
echo ""
echo "[2/4] Removing demo environments..."

kubectl delete -k "$PROJECT_DIR/k8s/overlays/dev" 2>/dev/null || true
kubectl delete -k "$PROJECT_DIR/k8s/overlays/staging" 2>/dev/null || true
kubectl delete -k "$PROJECT_DIR/k8s/overlays/prod" 2>/dev/null || true
kubectl delete -k "$PROJECT_DIR/k8s/overlays/dev-cnpg" 2>/dev/null || true

# ─── Remove namespaces ───
echo ""
echo "[3/4] Removing namespaces..."

kubectl delete namespace demo-dev 2>/dev/null || true
kubectl delete namespace demo-staging 2>/dev/null || true
kubectl delete namespace demo-prod 2>/dev/null || true

# ─── Remove ArgoCD (optional) ───
echo ""
read -p "Also remove ArgoCD? (y/N): " remove_argocd
if [[ "$remove_argocd" == "y" || "$remove_argocd" == "Y" ]]; then
  echo "[4/4] Removing ArgoCD..."
  kubectl delete namespace argocd 2>/dev/null || true
  echo "  ArgoCD removed."
else
  echo "[4/4] Keeping ArgoCD."
fi

# ─── Remove CNPG operator (optional) ───
echo ""
read -p "Also remove CNPG operator? (y/N): " remove_cnpg
if [[ "$remove_cnpg" == "y" || "$remove_cnpg" == "Y" ]]; then
  echo "Removing CNPG operator..."
  kubectl delete -f \
    https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.25/releases/cnpg-1.25.1.yaml \
    2>/dev/null || true
  echo "  CNPG operator removed."
else
  echo "Keeping CNPG operator."
fi

# ─── Remove Docker images (optional) ───
echo ""
read -p "Also remove Docker images? (y/N): " remove_images
if [[ "$remove_images" == "y" || "$remove_images" == "Y" ]]; then
  docker rmi api:latest 2>/dev/null || true
  docker rmi web:latest 2>/dev/null || true
  docker rmi localhost:5000/api:dev 2>/dev/null || true
  docker rmi localhost:5000/web:dev 2>/dev/null || true
  echo "  Docker images removed."
fi

echo ""
echo "========================================="
echo "  Cleanup complete!"
echo "========================================="
echo ""
echo "  Verify: kubectl get namespaces"
echo ""
