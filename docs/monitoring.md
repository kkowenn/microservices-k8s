# Optional Monitoring Stack

This setup adds Prometheus, Grafana, Alertmanager, Loki, Alloy, PostgreSQL exporter, and Kubernetes metrics to the local cluster.

Monitoring is optional and runs separately from the main application. Chart versions are pinned in `k8s/monitoring/charts.env`.

## Requirements

- Helm 3, kubectl, Python 3
- 4 CPUs, 8 GiB RAM, 20 GiB free disk
- Default Kubernetes StorageClass
- Standalone PostgreSQL (CNPG is not supported by this setup)

For Minikube:

```bash
MINIKUBE_CPUS=4 MINIKUBE_MEMORY=8192 bash scripts/minikube.sh
```

## Installation

Run from the repository root.

```bash
export KUBE_CONTEXT=kind-kind
export APP_NAMESPACE=demo-dev
```

Create monitoring credentials:

```bash
credentials_dir=$(mktemp -d)
chmod 700 "$credentials_dir"

python3 - "$credentials_dir" <<'PY'
from pathlib import Path
import os, secrets, sys

for name in ("grafana-password", "postgres-monitoring-password"):
    p = Path(sys.argv[1]) / name
    p.write_text(secrets.token_urlsafe(32))
    os.chmod(p, 0o600)
PY
```

Create the namespace and Secrets:

```bash
kubectl --context="$KUBE_CONTEXT" create namespace monitoring \
  --dry-run=client -o yaml | \
  kubectl --context="$KUBE_CONTEXT" apply -f -

kubectl --context="$KUBE_CONTEXT" -n monitoring \
  create secret generic grafana-admin \
  --from-literal=admin-user=admin \
  --from-file="admin-password=$credentials_dir/grafana-password" \
  --dry-run=client -o yaml | \
  kubectl --context="$KUBE_CONTEXT" -n monitoring apply --server-side -f -
```

Install the database monitoring role and stack:

```bash
bash scripts/monitoring/create-db-monitoring-role.sh \
  "$credentials_dir/postgres-monitoring-password"

bash scripts/monitoring/install.sh
```

The database helper creates a read-only monitoring role (`metrics_reader`) using `pg_monitor`. Keep passwords out of Git and remove temporary files after saving them securely.

## Access Grafana

```bash
kubectl --context="$KUBE_CONTEXT" -n monitoring \
  port-forward svc/monitoring-grafana 3001:80
```

Open **http://localhost:3001**

- Username: `admin`
- Password: Generated in `grafana-password`
- Dashboard: `Microservices — API, database and logs`

Prometheus and Loki datasources are provisioned automatically.

## Metrics and Logs

The API exposes metrics on port `9090`, separately from application traffic on `8000`.

Example PromQL:

```promql
up{service="api-metrics"}
pg_up{service="postgres-exporter"}
probe_success{service="gateway-probe"}
go_sql_in_use_connections{db_name="postgres"}
```

Example LogQL:

```logql
{namespace="demo-dev", app="api"} | json | level="ERROR"
{namespace="demo-dev", app="api"} | json | request_id="REQUEST_ID"
```

Alloy collects logs from the application namespace. The gateway probe checks `/api/items` every 15 seconds.

## Storage

| Component | PVC | Retention |
|---|---|---|
| Prometheus | 5 GiB | 3 days / 4 GB |
| Loki | 5 GiB | 72 hours |
| Grafana | 1 GiB | Persistent dashboards |
| Alertmanager | 1 GiB | Alert state |

This is a single-node local setup, not HA. PVCs do not replace backups. NetworkPolicy enforcement also depends on the cluster CNI.

## Alerts

Alerts are enabled, but external notifications are disabled by default.

To enable Slack, create the `alertmanager-slack` Secret with key `url`, review `k8s/monitoring/notifications/slack-values.yaml`, then run:

```bash
source k8s/monitoring/charts.env

helm --kube-context "$KUBE_CONTEXT" upgrade monitoring \
  prometheus-community/kube-prometheus-stack \
  --version "$PROMETHEUS_CHART_VERSION" \
  -n monitoring \
  -f k8s/monitoring/kube-prometheus-values.yaml \
  -f k8s/monitoring/notifications/slack-values.yaml \
  --wait
```

## Validation

```bash
(cd services/api && go test -race ./... && go vet ./...)

python3 -m pip install -r tests/requirements.txt

bash scripts/monitoring/validate.sh
python3 scripts/test/test-monitoring.py
```

To test database outage and recovery in an **isolated test namespace only**:

```bash
python3 scripts/monitoring/exercise.py
```

The exercise stops PostgreSQL, checks that alerts fire, restores the database, and verifies that application data is preserved.

See [runbook](runbook.md) and [outage test results](postmortem-db-outage.md) for details.

**Note:** Do not delete application PVCs or the application namespace when removing monitoring. Review monitoring PVCs, Secrets, and CRDs before cleanup.