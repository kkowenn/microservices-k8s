#!/usr/bin/env bash
# Only run in an isolated test namespace: this temporarily stops PostgreSQL.
set -euo pipefail
: "${KUBE_CONTEXT:?Set KUBE_CONTEXT to an explicit test cluster context}"
: "${NAMESPACE:?Set NAMESPACE to an isolated test namespace}"
OUTAGE_TEST_PORT="${OUTAGE_TEST_PORT:-18000}"
kube=(kubectl --context="$KUBE_CONTEXT" -n "$NAMESPACE")
replicas=$("${kube[@]}" get statefulset/postgres -o jsonpath='{.spec.replicas}')
[[ "$replicas" == 1 ]] || { echo "Expected one standalone PostgreSQL instance" >&2; exit 1; }
api_pod=$("${kube[@]}" get pods -l app=api -o jsonpath='{.items[0].metadata.name}')
identity() {
  "${kube[@]}" get pod "$api_pod" -o jsonpath='{.metadata.uid}:{.status.containerStatuses[0].restartCount}'
}
before=$(identity)
log=$(mktemp)
forward_pid=
stopped=false
cleanup() {
  if [[ "$stopped" == true ]]; then
    "${kube[@]}" scale statefulset/postgres --replicas="$replicas" || true
  fi
  if [[ -n "$forward_pid" ]]; then kill "$forward_pid" 2>/dev/null || true; fi
  rm -f "$log"
}
trap cleanup EXIT
"${kube[@]}" port-forward --address=127.0.0.1 "pod/$api_pod" "$OUTAGE_TEST_PORT:8000" >"$log" 2>&1 &
forward_pid=$!
base="http://127.0.0.1:$OUTAGE_TEST_PORT"
ready=false
for attempt in {1..30}; do
  if curl -fsS --max-time 8 "$base/readyz" >/dev/null 2>&1; then ready=true; break; fi
  kill -0 "$forward_pid" || { cat "$log"; exit 1; }
  sleep 1
done
[[ "$ready" == true ]] || { cat "$log"; exit 1; }
items_before=$(curl -fsS --max-time 8 "$base/api/items")
stopped=true
"${kube[@]}" scale statefulset/postgres --replicas=0
"${kube[@]}" wait --for=delete pod/postgres-0 --timeout=90s
# Span more than three liveness probe periods to catch a restart regression.
for attempt in {1..9}; do
  [[ $(curl -sS --max-time 8 -o /dev/null -w '%{http_code}' "$base/livez") == 200 ]]
  [[ $(curl -sS --max-time 8 -o /dev/null -w '%{http_code}' "$base/readyz") == 503 ]]
  [[ $(curl -sS --max-time 8 -o /dev/null -w '%{http_code}' "$base/api/items") == 503 ]]
  [[ $(identity) == "$before" ]] || { echo "API restarted during database outage" >&2; exit 1; }
  sleep 5
done
"${kube[@]}" scale statefulset/postgres --replicas="$replicas"
"${kube[@]}" rollout status statefulset/postgres --timeout=180s
stopped=false
ready=false
for attempt in {1..30}; do
  if curl -fsS --max-time 8 "$base/readyz" >/dev/null 2>&1; then ready=true; break; fi
  sleep 2
done
[[ "$ready" == true ]]
[[ $(curl -fsS --max-time 8 "$base/api/items") == "$items_before" ]]
[[ $(identity) == "$before" ]]
echo "Database outage/recovery, API liveness and preserved items: PASS"
