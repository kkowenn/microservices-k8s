#!/usr/bin/env bash
# Make a backup and restore it into a new, temporary database. Never overwrite
# the application database. Use only an isolated local/test namespace.

# Stop execution when errors occur
set -euo pipefail

# Set kube and create 1 unique name
CONTEXT="${KUBE_CONTEXT:-kind-kind}"
NAMESPACE="${NAMESPACE:-demo-dev}"
backup_job="postgres-backup-test-$(date +%s)-$RANDOM"
restore_pod="${backup_job}-restore"
kube=(kubectl --context="$CONTEXT" -n "$NAMESPACE")

# Remove temporary Kubernetes resources after testing
cleanup() {
  "${kube[@]}" delete pod "$restore_pod" --ignore-not-found --wait=false >/dev/null || true
  "${kube[@]}" delete job "$backup_job" --ignore-not-found --wait=false >/dev/null || true
}
trap cleanup EXIT

# Trigger backup Job from the existing PostgreSQL CronJob
"${kube[@]}" create job "$backup_job" --from=cronjob/postgres-backup
if ! "${kube[@]}" wait --for=condition=complete "job/$backup_job" --timeout=660s; then
  "${kube[@]}" logs "job/$backup_job" || true
  exit 1
fi

# backup logs
logs=$("${kube[@]}" logs "job/$backup_job")
printf '%s\n' "$logs"
backup_file=$(awk '/^Backup completed: / { print $3 }' <<< "$logs")

# Validate that the backup filename is safe and ends with .tar
[[ "$backup_file" =~ ^[a-zA-Z0-9_.-]+\.tar$ ]] || { echo "Missing valid backup filename" >&2; exit 1; }

# Pass backup metadata while loading database credentials from Kubernetes Secret
BACKUP_FILE="$backup_file" RESTORE_POD="$restore_pod" NAMESPACE="$NAMESPACE" python3 - <<'PY' | "${kube[@]}" apply -f -
import json, os
script = '''set -eu
export PGUSER="$POSTGRES_USER" PGPASSWORD="$POSTGRES_PASSWORD"
backup="/backups/$BACKUP_FILE"
test -s "$backup"
pg_restore --list "$backup" >/dev/null
scratch="restore_check_$(date +%s)_$$"
createdb "$scratch"
trap 'dropdb --if-exists "$scratch"' EXIT
pg_restore --exit-on-error --no-owner --no-privileges --dbname="$scratch" "$backup"
query="SELECT coalesce(json_agg(t ORDER BY id)::text, '[]') FROM (SELECT id, name FROM items) t"
source=$(psql -X -v ON_ERROR_STOP=1 -At --dbname="$POSTGRES_DB" -c "$query")
restored=$(psql -X -v ON_ERROR_STOP=1 -At --dbname="$scratch" -c "$query")
[ "$source" = "$restored" ]
echo "Backup restore and item comparison: PASS"
'''
pod = {"apiVersion":"v1", "kind":"Pod", "metadata":{"name":os.environ["RESTORE_POD"], "namespace":os.environ["NAMESPACE"]},
 "spec":{"restartPolicy":"Never", "activeDeadlineSeconds":180, "automountServiceAccountToken":False,
 "containers":[{"name":"restore", "image":"postgres:16-alpine", "imagePullPolicy":"IfNotPresent",
 "envFrom":[{"secretRef":{"name":"postgres-admin-credentials"}}],
 "env":[{"name":k,"value":v} for k,v in {"PGHOST":"postgres", "PGPORT":"5432", "PGCONNECT_TIMEOUT":"10", "BACKUP_FILE":os.environ["BACKUP_FILE"]}.items()],
 "command":["/bin/sh","-c",script], "volumeMounts":[{"name":"backups","mountPath":"/backups","readOnly":True}]}],
 "volumes":[{"name":"backups","persistentVolumeClaim":{"claimName":"postgres-backups"}}]}}
print(json.dumps(pod))
PY
if ! "${kube[@]}" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$restore_pod" --timeout=200s; then
  "${kube[@]}" logs "$restore_pod" || true
  exit 1
fi
"${kube[@]}" logs "$restore_pod"
