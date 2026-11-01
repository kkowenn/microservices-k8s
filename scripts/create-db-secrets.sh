#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 4 ]]; then
  echo "Usage: $0 CONTEXT NAMESPACE ADMIN_ENV_FILE APP_ENV_FILE" >&2
  echo "Each file needs POSTGRES_USER, POSTGRES_PASSWORD and POSTGRES_DB; keep files outside Git." >&2
  exit 1
fi
context=$1
namespace=$2
admin_file=$3
app_file=$4
[[ -n "$context" && -n "$namespace" ]] || {
  echo "An explicit, nonempty context and namespace are required." >&2
  exit 1
}
for file in "$admin_file" "$app_file"; do
  [[ -r "$file" ]] || { echo "Cannot read credential file." >&2; exit 1; }
done
# Validate both files before changing cluster state. Values never enter output.
python3 - "$admin_file" "$app_file" <<'VALIDATE'
import sys

def read_file(path):
    values = {}
    for line in open(path):
        line = line.rstrip("\r\n").lstrip()
        if not line or line.startswith("#"):
            continue
        key, sep, value = line.partition("=")
        if not sep or key in values:
            raise ValueError("Use unique KEY=value lines in credential files")
        values[key] = value
    for key in ("POSTGRES_USER", "POSTGRES_PASSWORD", "POSTGRES_DB"):
        if not values.get(key):
            raise ValueError("Each credential file needs nonempty POSTGRES_USER, POSTGRES_PASSWORD and POSTGRES_DB")
    return values

try:
    admin, app = map(read_file, sys.argv[1:])
    if admin["POSTGRES_DB"] != app["POSTGRES_DB"]:
        raise ValueError("Admin and application must name the same database")
    if admin["POSTGRES_USER"] == app["POSTGRES_USER"] or admin["POSTGRES_PASSWORD"] == app["POSTGRES_PASSWORD"]:
        raise ValueError("Use distinct admin/app usernames and passwords")
except (OSError, ValueError):
    sys.exit("Invalid credential files: require unique KEY=value entries, nonempty database fields, matching database names and distinct admin/app usernames and passwords.")
VALIDATE
kubectl --context="$context" create namespace "$namespace" --dry-run=client -o yaml |
  kubectl --context="$context" apply -f -
for spec in "postgres-admin-credentials:$admin_file" "postgres-credentials:$app_file"; do
  kubectl --context="$context" -n "$namespace" create secret generic "${spec%%:*}" \
    --from-env-file="${spec#*:}" --dry-run=client -o yaml |
    kubectl --context="$context" -n "$namespace" apply --server-side --field-manager=db-secret-setup -f -
done
