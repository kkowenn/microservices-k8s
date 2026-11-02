#!/usr/bin/env bash
# Stop script when errors occur
set -euo pipefail

# Require Kubernetes context and ns
: "${KUBE_CONTEXT:?Set an explicit KUBE_CONTEXT}"
: "${APP_NAMESPACE:?Set APP_NAMESPACE}"

# Validate the provided password file
[[ $# == 1 && -s "$1" ]] || { echo "Usage: $0 PASSWORD_FILE (keep outside Git)" >&2; exit 1; }
kube=(kubectl --context="$KUBE_CONTEXT" -n "$APP_NAMESPACE")
"${kube[@]}" get statefulset/postgres >/dev/null
"${kube[@]}" get secret/postgres-admin-credentials >/dev/null
"${kube[@]}" create secret generic postgres-monitoring-credentials --from-file="password=$1" --dry-run=client -o yaml |
  "${kube[@]}" apply --server-side --field-manager=monitoring-setup -f -
  
# create and configure a dedicated PostgreSQL monitoring user
job="monitoring-role-$(date +%s)-$RANDOM"
trap '"${kube[@]}" delete job "$job" --ignore-not-found --wait=false >/dev/null' EXIT
JOB_NAME="$job" python3 - <<'PY' | "${kube[@]}" apply -f -
import json, os
sql = r'''set -eu
psql -X -v ON_ERROR_STOP=1 <<'SQL'
\getenv password MONITORING_PASSWORD
\getenv db PGDATABASE
SELECT 'CREATE ROLE metrics_reader' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'metrics_reader') \gexec
ALTER ROLE metrics_reader LOGIN PASSWORD :'password' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
GRANT pg_monitor TO metrics_reader;
GRANT CONNECT ON DATABASE :"db" TO metrics_reader;
SQL
'''
def secret_env(name, secret, key):
    return {"name":name,"valueFrom":{"secretKeyRef":{"name":secret,"key":key}}}
container = {"name":"provision", "image":"postgres:16-alpine", "command":["/bin/sh","-c",sql], "env":[
 {"name":"PGHOST","value":"postgres"}, {"name":"PGCONNECT_TIMEOUT","value":"5"},
 secret_env("PGUSER","postgres-admin-credentials","POSTGRES_USER"),
 secret_env("PGPASSWORD","postgres-admin-credentials","POSTGRES_PASSWORD"),
 secret_env("PGDATABASE","postgres-admin-credentials","POSTGRES_DB"),
 secret_env("MONITORING_PASSWORD","postgres-monitoring-credentials","password")],
 "resources":{"requests":{"cpu":"10m","memory":"32Mi"},"limits":{"memory":"128Mi"}}}
print(json.dumps({"apiVersion":"batch/v1","kind":"Job","metadata":{"name":os.environ['JOB_NAME']},
 "spec":{"backoffLimit":0,"activeDeadlineSeconds":120,"template":{"spec":{
 "restartPolicy":"Never","automountServiceAccountToken":False,"containers":[container]}}}}))
PY
if ! "${kube[@]}" wait --for=condition=complete "job/$job" --timeout=150s; then
  "${kube[@]}" logs "job/$job" || true
  exit 1
fi
echo "Dedicated PostgreSQL monitoring role and Secret configured."
# Refresh an existing exporter after password rotation.
if "${kube[@]}" get deployment/postgres-exporter >/dev/null 2>&1; then
  "${kube[@]}" rollout restart deployment/postgres-exporter
fi
