#!/usr/bin/env bash
set -euo pipefail
: "${KUBE_CONTEXT:?Set an explicit KUBE_CONTEXT}"
: "${APP_NAMESPACE:?Set APP_NAMESPACE to the deployed standalone application namespace}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# env
source "$ROOT/k8s/monitoring/charts.env"

# Loop check Dependencies of helm kubectl & Error Message at stderr
for tool in helm kubectl; do command -v "$tool" >/dev/null || { echo "$tool is required" >&2; exit 1; }; done

# kubectl --context=microservices-k8s get pods
kube=(kubectl --context="$KUBE_CONTEXT")
helm_cmd=(helm --kube-context "$KUBE_CONTEXT")

# Secret postgres-monitoring-credentials
"${kube[@]}" -n "$APP_NAMESPACE" get secret/postgres-monitoring-credentials >/dev/null
# Secret grafana-admin
"${kube[@]}" -n monitoring get secret/grafana-admin >/dev/null

# add Helm Repository
"${helm_cmd[@]}" repo add prometheus-community https://prometheus-community.github.io/helm-charts
"${helm_cmd[@]}" repo add grafana https://grafana.github.io/helm-charts
"${helm_cmd[@]}" repo update

# Deploy Prometheus Operator, Prometheus, Grafana, 
"${helm_cmd[@]}" upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --version "$PROMETHEUS_CHART_VERSION" -n monitoring --create-namespace \
  -f "$ROOT/k8s/monitoring/kube-prometheus-values.yaml" --wait --timeout 10m

# install || upgrade loki 
"${helm_cmd[@]}" upgrade --install loki grafana/loki --version "$LOKI_CHART_VERSION" \
  -n monitoring -f "$ROOT/k8s/monitoring/loki-values.yaml" --wait --timeout 10m

# install || upgrade alloy
"${helm_cmd[@]}" upgrade --install alloy grafana/alloy --version "$ALLOY_CHART_VERSION" \
  -n monitoring -f "$ROOT/k8s/monitoring/alloy-values.yaml" --wait --timeout 5m

# install || upgrade postgres-exporter
"${helm_cmd[@]}" upgrade --install postgres-exporter prometheus-community/prometheus-postgres-exporter \
  --version "$POSTGRES_EXPORTER_CHART_VERSION" -n "$APP_NAMESPACE" \
  -f "$ROOT/k8s/monitoring/postgres-exporter-values.yaml" \
  --set-string "config.datasource.database=${DATABASE_NAME:-demodb}" --wait --timeout 5m

# apply
# 3001 = Local Port
# 80 = Service Port ภายใน Kubernetes
"${kube[@]}" -n "$APP_NAMESPACE" apply -k "$ROOT/k8s/monitoring/application"
"${kube[@]}" apply -k "$ROOT/k8s/monitoring"
echo "Monitoring installed. Forward Grafana: kubectl --context=$KUBE_CONTEXT -n monitoring port-forward svc/monitoring-grafana 3001:80"
