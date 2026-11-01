# Optional observability stack

The default application deployment needs no monitoring CRDs. This opt-in local
profile adds Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics,
PostgreSQL exporter, Loki, Alloy, and an internal gateway availability probe.
Chart versions are pinned in `k8s/monitoring/charts.env`.

## Capacity and prerequisites

Use Helm 3, kubectl, Python 3, the current instrumented application image, and a
cluster with a default StorageClass. Budget **4 CPUs, 8 GiB RAM, and at least
20 GiB free disk** for the complete local stack. Docker VFS/native snapshotting
can require substantially more disk because image layers are copied. Retention
and resource limits do not guarantee it will fit on every laptop.

The normal Minikube defaults remain app-sized. For monitoring:

```bash
MINIKUBE_CPUS=4 MINIKUBE_MEMORY=8192 bash scripts/minikube.sh
```

For Kind, allocate resources in Docker before creating the cluster. Do not delete
an existing cluster or database volume to resize it. Complete the existing
credential migration in [setup.md](setup.md) before upgrading old databases.

## Install

Run from the repository root. Use an isolated namespace for outage exercises.
This exporter profile targets **standalone PostgreSQL**, not the CNPG overlay.

```bash
export KUBE_CONTEXT=kind-kind
export APP_NAMESPACE=demo-dev
```

Keep passwords outside Git. Create private files containing only each password,
without a trailing newline. For example:

```bash
credentials_dir=$(mktemp -d)
chmod 700 "$credentials_dir"
python3 - "$credentials_dir" <<'PY'
from pathlib import Path
import os, secrets, sys
for name in ('grafana-password', 'postgres-monitoring-password'):
    p = Path(sys.argv[1]) / name
    p.write_text(secrets.token_urlsafe(32))
    os.chmod(p, 0o600)
PY
kubectl --context="$KUBE_CONTEXT" create namespace monitoring --dry-run=client -o yaml |
  kubectl --context="$KUBE_CONTEXT" apply -f -
kubectl --context="$KUBE_CONTEXT" -n monitoring create secret generic grafana-admin \
  --from-literal=admin-user=admin \
  --from-file="admin-password=$credentials_dir/grafana-password" \
  --dry-run=client -o yaml |
  kubectl --context="$KUBE_CONTEXT" -n monitoring apply --server-side -f -
bash scripts/monitoring/create-db-monitoring-role.sh "$credentials_dir/postgres-monitoring-password"
bash scripts/monitoring/install.sh
```

The role helper runs a temporary provisioning Job using the existing
`postgres-admin-credentials` Secret. It creates/rotates `metrics_reader` with
`pg_monitor` and database CONNECT, then stores the independent password in
`postgres-monitoring-credentials`. It grants no superuser access and reuses
neither the administrator nor application password. `pg_monitor` can observe
server/query statistics; treat it as privileged observability access. This helper
works on new and already initialized standalone databases without modifying rows
or rerunning initialization SQL. It restarts an existing exporter after rotation.
Store credentials in a password manager, then remove temporary files.

The default database is `demodb`; set `DATABASE_NAME` before installation for a
different name. Configure the exporter host and TLS/CA settings for other systems.
CNPG needs its own monitoring credential/exporter setup. Local database traffic
is unencrypted.

The installer installs operator CRDs before optional application resources.
Helm does not automatically upgrade all CRDs: review upstream upgrade instructions
when changing the pinned operator chart. Normal app overlays remain CRD-free.

## Access and behavior

```bash
kubectl --context="$KUBE_CONTEXT" -n monitoring port-forward --address=127.0.0.1 svc/monitoring-grafana 3001:80
```

Open http://localhost:3001 and sign in as `admin` with the generated password.
The **Microservices — API, database and logs** dashboard, Prometheus datasource,
and Loki datasource are provisioned from Git. Select the application namespace.
Rate/latency panels need traffic and multiple scrapes. The gateway probe requests
`/api/items` every 15 seconds, providing a small steady request stream.

The API serves application traffic on 8000 and metrics on a separate 9090 listener.
`/metrics` returns 404 through NGINX and the application listener. `api-metrics`
is ClusterIP-only and publishes running but unready pods so database failure
cannot hide telemetry. Its NetworkPolicy allows metrics only from Prometheus
pods in `monitoring`, while allowing normal traffic on 8000. **Enforcement needs
a policy-capable CNI**; Kind's default kindnet does not enforce NetworkPolicy.
Existing additive policies can widen access. Keep a local cluster trusted.

Metrics use fixed routes and bounded methods/statuses. Database pool metrics are
`go_sql_*` with `db_name="postgres"`, not `postgres_sql_*`. The saturation alert
uses in-use/max connections plus growing waits; idle open connections are normal.
Probe and scrape requests do not affect application request metrics. Generated
request IDs correlate JSON request and error logs; query strings, authorization
headers, and bodies are not logged. Request IDs are not metric or Loki labels.

Alloy tails logs through the Kubernetes API, without mounting host log files.
The DaemonSet selects pods on its own node to avoid duplicate streams. It collects
only `demo-.*` namespaces and pods labeled `app=api|web|nginx|postgres`; adjust
those filters for other names. Namespace, app, pod and container are stream labels.

```promql
up{service="api-metrics"}
pg_up{service="postgres-exporter"}
probe_success{service="gateway-probe"}
go_sql_in_use_connections{db_name="postgres"}
```

```logql
{namespace="demo-dev", app="api"} | json | level="ERROR"
{namespace="demo-dev", app="api"} | json | request_id="REQUEST_ID"
```

Prometheus retains three days / 4 GB on a 5 GiB PVC. Loki uses a 5 GiB PVC with
72-hour retention and compaction. Grafana and Alertmanager each use a 1 GiB PVC.
Retention is not a hard disk quota; monitor disk use. These local volumes are not
independent backups or protection against node loss. This profile is not HA.
Control-plane scrape endpoints vary between local clusters, so etcd, scheduler,
controller-manager, and kube-proxy scraping are disabled. Node-exporter avoids
host-root mounts for Docker compatibility, making its filesystem view container
relative. Kubelet/cAdvisor and kube-state-metrics supply application pod metrics.

## External notifications

The default receiver `null` sends nothing outside the cluster; alerts still appear
in Prometheus/Alertmanager. To enable Slack, create `alertmanager-slack` in
`monitoring` with key `url` from a private webhook file, then review the channel
in `k8s/monitoring/notifications/slack-values.yaml` and run:

```bash
source k8s/monitoring/charts.env
helm --kube-context "$KUBE_CONTEXT" upgrade monitoring prometheus-community/kube-prometheus-stack \
  --version "$PROMETHEUS_CHART_VERSION" -n monitoring \
  -f k8s/monitoring/kube-prometheus-values.yaml \
  -f k8s/monitoring/notifications/slack-values.yaml --wait
```

This enables real messages. The default installer restores disabled notifications
when rerun. Discord/email require their own reviewed receiver configuration;
an arbitrary Discord webhook cannot consume Slack payloads directly.

## Validate

```bash
(cd services/api && go test -race ./... && go vet ./...)
python3 -m pip install -r tests/requirements.txt
# Requires Helm, kubectl, and promtool v3.2.1 on PATH.
bash scripts/monitoring/validate.sh
python3 scripts/test/test-monitoring.py
```

Configuration validation lints/renders all four charts, verifies discovery labels,
checks dashboard provisioning, compares deployed and tested rules, and tests alert
firing/recovery, missing targets, idle/busy pools, zero traffic, errors, latency,
and restarts with promtool. `CHART_DIR` can name already extracted pinned charts
for offline validation. Live checks verify targets, database/gateway metrics,
Loki ingestion, and Grafana provisioning. Grafana credentials stay in memory.

**Only in an isolated test namespace**, run:

```bash
python3 scripts/monitoring/exercise.py
```

The exercise stops PostgreSQL for at least three minutes, expects `DatabaseDown`
and `GatewayUnavailable` to fire while API metrics remain available, restores
the single instance, verifies unchanged API restart counts and preserved items,
and waits for alert resolution. It attempts recovery on failure and never deletes
PVCs. Simply deleting a database pod may recover before the alert's `for` period.

CI checks configuration on changes. The **Monitoring runtime** workflow runs on relevant pushes and can also be
manually dispatched. It installs and exercises the full stack in a fresh Kind cluster. See
[runbooks](runbook.md) and the [exercise evidence](postmortem-db-outage.md).

Uninstall Helm releases and remove optional application resources using explicit
context/namespace. Leave PVCs and external Secrets for review. Do not delete the
application namespace or its database PVC. Operator CRDs may serve other stacks;
remove them only after confirming no remaining users.
