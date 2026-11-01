#!/usr/bin/env bash
set -euo pipefail
CONTEXT="${KUBE_CONTEXT:-kind-kind}"
NAMESPACE="${NAMESPACE:-demo-dev}"
SMOKE_PORT="${SMOKE_PORT:-13000}"
log=$(mktemp)
kubectl --context="$CONTEXT" -n "$NAMESPACE" port-forward --address=127.0.0.1 svc/nginx "$SMOKE_PORT:80" >"$log" 2>&1 &
forward_pid=$!
trap 'kill "$forward_pid" 2>/dev/null || true; rm -f "$log"' EXIT
ready=false
for attempt in {1..30}; do
  if curl -fsS "http://127.0.0.1:$SMOKE_PORT/nginx-health" >/dev/null; then ready=true; break; fi
  kill -0 "$forward_pid" || { cat "$log"; exit 1; }
  sleep 1
done
[[ "$ready" == true ]] || { cat "$log"; exit 1; }
curl -fsS "http://127.0.0.1:$SMOKE_PORT/" | python3 -c 'import sys; s=sys.stdin.read(); assert "Microservices K8s" in s and "/client.js" in s'
curl -fsS "http://127.0.0.1:$SMOKE_PORT/client.js" >/dev/null
curl -fsS "http://127.0.0.1:$SMOKE_PORT/api/items" | python3 -c 'import json,sys; assert json.load(sys.stdin)==[{"id":1,"name":"Item A"},{"id":2,"name":"Item B"},{"id":3,"name":"Item C"}]'
kubectl --context="$CONTEXT" -n "$NAMESPACE" exec deployment/api -- wget -qO- http://localhost:8000/readyz
printf '\nGateway, frontend and seeded API: PASS\n'
