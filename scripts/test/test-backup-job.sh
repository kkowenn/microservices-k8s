backup_job="postgres-backup-sa-test-$(date +%s)"

kubectl --context=kind-kind -n demo-dev create job \
  "$backup_job" --from=cronjob/postgres-backup

kubectl --context=kind-kind -n demo-dev wait \
  --for=condition=complete "job/$backup_job" --timeout=660s

kubectl --context=kind-kind -n demo-dev logs "job/$backup_job"

kubectl --context=kind-kind -n demo-dev get pods \
  -l "job-name=$backup_job" \
  -o 'custom-columns=NAME:.metadata.name,SA:.spec.serviceAccountName,AUTOMOUNT:.spec.automountServiceAccountToken'