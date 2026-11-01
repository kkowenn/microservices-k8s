# Setup and operations guide

[Back to the README](../README.md)

## Local setup

Run all commands from the repository root. Choose either Kind or Minikube.
The Kind path was verified locally: all four services became ready, and
`/api/items` returned the three seeded database records.

### Prerequisites

- Docker Desktop running on macOS, or Docker Engine running on Linux.
- `kubectl` and either `kind` or `minikube`.
- Internet access for the first image downloads.

Docker Desktop's built-in Kubernetes does not need to be enabled for these
setups. Both use Docker to run their own Kubernetes nodes.

On macOS, install the command-line tools with Homebrew:

```bash
# For Kind
brew install kubectl kind

# Or, for Minikube
brew install kubectl minikube

# Confirm Docker is running
docker info
```

### Option 1: Kind

Check for an existing cluster:

```bash
kind get clusters
```

If a cluster named `kind` does not exist, create it once:

```bash
kind create cluster --name kind
```

Build and deploy the application:

```bash
bash scripts/kind.sh
```

The script builds `api:local` and `web:local`, loads them into the cluster,
applies `k8s/overlays/local`, restarts the application pods, and waits for all
services to be ready. It targets context `kind-kind` without changing your
current kubectl context.

Start the port-forward in a terminal and leave it running:

```bash
kubectl --context=kind-kind -n demo-dev port-forward --address=127.0.0.1 svc/nginx 3000:80
```

Open **http://localhost:3000**. The page should display Item A, Item B, and Item C.
The API is available at **http://localhost:3000/api/items**.

For a cluster with a different name:

```bash
KIND_CLUSTER_NAME=my-cluster bash scripts/kind.sh
kubectl --context=kind-my-cluster -n demo-dev port-forward svc/nginx 3000:80
```

### Option 2: Minikube

```bash
bash scripts/minikube.sh
kubectl --context=microservices-k8s -n demo-dev port-forward --address=127.0.0.1 svc/nginx 3000:80
```

The script creates or starts a dedicated `microservices-k8s` cluster using the
Docker driver, 2 CPUs, and 3 GiB of memory. It builds and loads the application
images, applies the same local overlay, and waits for the services to be ready.
It preserves your current kubectl context.

Open **http://localhost:3000** and keep the port-forward running. The first
Minikube startup downloads large cluster images and can take several minutes.
The Minikube script is provided as an alternative; the completed local run was
verified on Kind.

### Local architecture and data

Local traffic follows this path:

```text
localhost:3000 → kubectl port-forward → NGINX gateway
                                       ├── /       → Web
                                       └── /api/*  → API → PostgreSQL
```

The local overlay runs one instance of each service in namespace `demo-dev`.
It uses locally loaded app images, so no image registry is needed. Access via
port-forward also needs no Ingress controller, `demo.local` host entry, or
ArgoCD installation.

PostgreSQL uses a 1 GiB persistent volume. The initialization SQL creates the
`items` table and seeds Item A, Item B, and Item C when the database is first
created. Rebuilding the app or restarting pods preserves that data. The local
overlay uses one PostgreSQL instance because the base database containers do
not configure replication.

### Verify the deployment

For Kind, run these commands in another terminal while port-forward is running:

```bash
kubectl --context=kind-kind -n demo-dev get pods
kubectl --context=kind-kind -n demo-dev get pvc
curl --fail http://localhost:3000/nginx-health
curl --fail http://localhost:3000/api/items
kubectl --context=kind-kind -n demo-dev exec deployment/api -- wget -qO- http://localhost:8000/health
```

For Minikube, replace `--context=kind-kind` with
`--context=microservices-k8s` in kubectl commands throughout this guide.

Expected results:

- The `api`, `web`, `nginx`, and `postgres-0` pods show `1/1 Running`.
- The PostgreSQL volume claim shows `Bound`.
- `/nginx-health` returns `ok`.
- `/api/items` returns the seeded records:

```json
[{"id":1,"name":"Item A"},{"id":2,"name":"Item B"},{"id":3,"name":"Item C"}]
```

The direct API health check should return
`{"status":"ok","database":"connected"}`.

### Rebuild after code changes

Run the setup script for your chosen cluster again:

```bash
# Kind
bash scripts/kind.sh

# Or Minikube
bash scripts/minikube.sh
```

The scripts reload the images and restart the API and web deployments. If the
port-forward exits during a rollout, start it again using the command above.

### Troubleshooting

| Symptom | Action |
|---------|--------|
| Cannot connect to the Docker daemon | Start Docker Desktop or Docker Engine and check `docker info`. |
| `kind-kind` context is missing | Check `kind get clusters`; create the cluster or use `KIND_CLUSTER_NAME` for its actual name. |
| Port 3000 is already in use | Reuse the existing port-forward, or run `kubectl --context=kind-kind -n demo-dev port-forward svc/nginx 3001:80` and open http://localhost:3001. |
| `ErrImageNeverPull` on API or web | Rerun the setup script to load the local images into the selected cluster. |
| NGINX or PostgreSQL shows `ImagePullBackOff` | Inspect pod events and check access to Docker Hub, then rerun setup after connectivity recovers. |
| Browser cannot connect | Keep the port-forward running and check that the pods are ready. |
| Setup times out | Inspect logs and events below; initial image downloads or database startup may still be in progress. |

```bash
kubectl --context=kind-kind -n demo-dev get events --sort-by=.lastTimestamp
kubectl --context=kind-kind -n demo-dev logs deployment/api --tail=50
kubectl --context=kind-kind -n demo-dev logs deployment/nginx --tail=50
kubectl --context=kind-kind -n demo-dev logs statefulset/postgres --tail=50
```

NGINX needs a writable `/tmp` even with a read-only root filesystem. Its manifest
includes an `emptyDir` volume for this; retain that mount when editing the
container configuration.

### Stop or remove the local deployment

Press **Ctrl+C** in the port-forward terminal to stop browser access. The
application and database continue running in Kubernetes.

To stop Minikube while preserving its data:

```bash
minikube stop -p microservices-k8s
# Resume later, then restart the port-forward
bash scripts/minikube.sh
```

To remove only this application's namespace from Kind:

```bash
# Deletes demo-dev resources and its database volume claim/data
kubectl --context=kind-kind delete namespace demo-dev
```

To remove an entire cluster, including its database data and any other workloads
in that cluster, use the command for the cluster you want to delete:

```bash
# Kind
kind delete cluster --name kind

# Or Minikube
minikube delete -p microservices-k8s
```

## ArgoCD and registry-based environments

The `dev`, `staging`, and `prod` overlays are separate from the local setup.
Dev expects `localhost:5000/api:dev` and `localhost:5000/web:dev`; staging and
production contain `registry.example.com` image references. Configure reachable
registries and publish matching images before using these overlays.

The ArgoCD applications in `argocd/` track the Git repository and these overlays.
Review their repository URL, revision, destination, and image settings before
applying them. The dev application automatically syncs to `demo-dev`, the same
namespace used by the local setup; enabling it there will reconcile the local
resources to the Git-managed dev configuration.

`scripts/setup.sh` is the older workflow that installs ArgoCD and applies all
environments using your current kubectl context. Its `api:latest` and
`web:latest` builds do not match the dev overlay's registry tags. Use
`scripts/kind.sh` or `scripts/minikube.sh` for the local setup described above.
Likewise, `scripts/cleanup.sh` targets multiple demo environments in the current
context; use the explicit local cleanup commands above for this setup.

## Architecture Diagrams

Auto-generate architecture diagrams from the Kubernetes manifests using [KubeDiagrams](https://github.com/philippemerle/KubeDiagrams). No live cluster required.

### Install prerequisites

```bash
# Python package
pip install KubeDiagrams

# Graphviz (macOS)
brew install graphviz kustomize

# Graphviz (Debian/Ubuntu)
sudo apt install graphviz
```

### Generate diagrams

```bash
./scripts/generate-diagrams.sh
```

### Output

| File | Description |
|------|-------------|
| `docs/diagrams/base.png` | Base manifests (all shared resources) |
| `docs/diagrams/dev.png` | Dev overlay (1 replica, local images) |
| `docs/diagrams/staging.png` | Staging overlay (2 replicas) |
| `docs/diagrams/prod.png` | Prod overlay (3 replicas) |
| `docs/diagrams/dev-cnpg.png` | Dev with CloudNativePG (requires CRDs) |

## Database credentials and existing installations

Only `k8s/overlays/local` includes demo credentials. The shared base and the
`dev`, `staging`, and `prod` overlays deliberately contain no Secret values.
Before deploying a standalone database in those environments, provision two
Secrets in the target namespace using your secret manager or:

```bash
bash scripts/create-db-secrets.sh CONTEXT NAMESPACE /secure/admin.env /secure/app.env
```

Keep both files outside the checkout and restrict file permissions to the owner
(`chmod 600`). Each file must contain `POSTGRES_USER`, `POSTGRES_PASSWORD`, and
`POSTGRES_DB`. Choose distinct administrator and application usernames, strong
independent passwords, and the same database name in both files. There are no
password defaults in the helper. It uses an explicit context and does not print
values or save a client-side last-applied copy of the Secret.

For **new volumes**, PostgreSQL initializes with `postgres-admin-credentials`,
then creates the role from `postgres-credentials` without superuser, role creation,
or database creation privileges. The API and backup job use that application role,
which receives only schema usage and SELECT access to the items table and its
sequence. Database administration uses the separate admin Secret. Credential
values already committed in Git must be considered public and rotated wherever
previously used; deleting the file does not remove Git history.

**Existing volumes require an explicit migration.** Initialization scripts run
only for an empty data directory. Updating a Kubernetes Secret does not create a
role, change a password, or remove the old superuser privilege in PostgreSQL.
Before applying these changes to an existing namespace:

1. Take and verify a backup with the current credentials. If multiple independent
   PostgreSQL pods already contain data, inspect and reconcile each database;
   scaling down cannot merge their contents. Preserve their PVCs.
2. During a maintenance window, use the existing database administrator to create
   the new administrator and application roles, set their passwords securely,
   and grant the application CONNECT, schema USAGE, and SELECT on `items` and
   `items_id_seq`. The application role must have NOSUPERUSER, NOCREATEDB,
   NOCREATEROLE, NOREPLICATION, and NOBYPASSRLS. Use a new role name if the old
   application role owns the database or is the bootstrap superuser.
3. Provision matching admin/app Secrets in that namespace, then deploy. Ensure
   the admin Secret names the existing database and a working administrator.
   Restart the API and PostgreSQL pods in a controlled rollout to refresh their
   environment variables. Verify reads and backup/restore, then revoke or rotate
   the old application credentials after checking ownership and dependencies.

Do not delete the namespace, cluster, or PVCs to apply this migration. The local
Secret values are for disposable development data only. A newly created local
volume uses `postgres` as administrator and `demouser` as a SELECT-only app role.
The standalone StatefulSet stays at one instance in every overlay; use an
operator such as CNPG when replication and failover are needed.

The API requires explicit `DATABASE_USER`, `DATABASE_PASSWORD`, and
`DATABASE_NAME`. Connections have a five-second connection timeout; readiness
checks have a two-second deadline and queries a five-second deadline.
`/livez` checks HTTP process health independently of PostgreSQL, `/readyz` checks
the database, and `/health` remains a readiness alias. A database outage makes
pods unready without triggering liveness restarts. For PostgreSQL deployments
with TLS, configure `DATABASE_SSLMODE=verify-full` and mount the appropriate CA
trust in the API container; the local demo uses unencrypted cluster traffic.

## CloudNativePG development overlay

`dev-cnpg` replaces the standalone StatefulSet, Service, initialization ConfigMap,
backup CronJob, backup PVC, and their service accounts. It does not run a second
standalone database or back up an obsolete database endpoint. CNPG generates
`cnpg-cluster-app` for the API. Seed SQL runs in the application database via
`postInitApplicationSQL` and grants table SELECT to the application owner.
Install the CNPG operator before using this overlay, and configure its own
backup/recovery destination before relying on it for durable workloads. Automated
CNPG backup is deliberately not supplied by the standalone `pg_dump` CronJob.
Changing overlays does not migrate existing PostgreSQL data to CNPG.

## Regression checks

```bash
(cd services/api && go test -race -count=1 ./... && go vet ./...)
node --test services/web/*.test.js
python3 -m pip install -r tests/requirements.txt
python3 -m unittest discover -s tests -v
```

The manifest tests require `kubectl` on PATH (or set `KUBECTL` to its path).
CI runs these checks plus a fresh Kind deployment, gateway/API smoke checks,
backup/restore, and database outage/recovery. To run the integration checks against an isolated
local/test namespace:

```bash
KUBE_CONTEXT=kind-kind NAMESPACE=demo-dev bash scripts/test/smoke.sh
KUBE_CONTEXT=kind-kind NAMESPACE=demo-dev bash scripts/test/test-backup-job.sh
KUBE_CONTEXT=kind-kind NAMESPACE=demo-dev bash scripts/test/test-database-outage.sh
```

The outage test temporarily scales PostgreSQL to zero in the explicitly named
test namespace, checks HTTP liveness, failed readiness, bounded query failures,
and unchanged API restart counts, then restores PostgreSQL and compares items.
It attempts to restore the original replica count on failure too. Run it only
in an isolated test namespace; it intentionally interrupts database availability.

The backup test fails if the Job fails or no completed backup is reported. It
reads the archive from that Job, restores into a unique scratch database using
the separate administrator Secret, and compares item IDs and names with the
source. It removes its Job, restore Pod, and scratch database afterward, while
retaining the generated backup. Run this in a quiescent test database; concurrent
writes can legitimately make the source differ from the backup. A forced Pod
termination can leave the uniquely named `restore_check_*` scratch database for
an administrator to remove. This test requires Python 3 and never restores over
the application database. Prove recovery and configure independent durable backup
storage before enabling the CronJob schedule in a real environment.
