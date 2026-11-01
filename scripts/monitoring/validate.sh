#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/k8s/monitoring/charts.env"
rendered=$(mktemp -d)
trap 'rm -rf "$rendered"' EXIT
if [[ -z "${CHART_DIR:-}" ]]; then
  CHART_DIR="$rendered/charts"
  mkdir -p "$CHART_DIR"
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
  helm repo add grafana https://grafana.github.io/helm-charts
  helm repo update
  helm pull prometheus-community/kube-prometheus-stack --version "$PROMETHEUS_CHART_VERSION" --untar --untardir "$CHART_DIR"
  helm pull grafana/loki --version "$LOKI_CHART_VERSION" --untar --untardir "$CHART_DIR"
  helm pull grafana/alloy --version "$ALLOY_CHART_VERSION" --untar --untardir "$CHART_DIR"
  helm pull prometheus-community/prometheus-postgres-exporter --version "$POSTGRES_EXPORTER_CHART_VERSION" --untar --untardir "$CHART_DIR"
fi
for chart in kube-prometheus-stack loki alloy prometheus-postgres-exporter; do
  case "$chart" in
    kube-prometheus-stack) release=monitoring; namespace=monitoring; values=kube-prometheus-values;;
    prometheus-postgres-exporter) release=postgres-exporter; namespace=demo-test; values=postgres-exporter-values;;
    *) release=$chart; namespace=monitoring; values=$chart-values;;
  esac
  helm lint "$CHART_DIR/$chart" -f "$ROOT/k8s/monitoring/$values.yaml"
  helm template "$release" "$CHART_DIR/$chart" -n "$namespace" --kube-version 1.35.0 \
    -f "$ROOT/k8s/monitoring/$values.yaml" > "$rendered/$chart.yaml"
done
MONITORING_RENDER_DIR="$rendered" python3 -m unittest discover -s "$ROOT/tests" -p test_monitoring.py -v
(cd "$ROOT/k8s/monitoring/alerts" && promtool check rules rules.yaml && promtool test rules rules.test.yaml)
