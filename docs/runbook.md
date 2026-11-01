# Application alert runbooks

Use an explicit kubectl context and namespace. Begin with read-only inspection.
Keep credentials and sensitive data out of logs, screenshots and tickets.

## APIDown

API targets are down or absent.

Inspect: Inspect API pod state, metrics Service endpoints, ServiceMonitor labels and NetworkPolicy. Database readiness failure should not hide metrics.

Recovery: Restore the process or scrape path. Confirm targets are UP and the gateway works.

## APIHighErrorRate

Over 5% of completed API requests fail for five minutes.

Inspect: Inspect JSON errors by request_id, request volume, database readiness and pool waits. Small volumes make one failure significant.

Recovery: Fix the underlying dependency. Verify sustained success; gateway failures before the API have a separate alert.

## APIHighLatencyP95

API p95 latency exceeds 300ms for ten minutes.

Inspect: Inspect database queries/locks, pool waits, CPU throttling and traffic. Low-volume histogram percentiles are estimates.

Recovery: Resolve the bottleneck and verify recovery over the five-minute rate window.

## DatabaseDown

PostgreSQL/exporter is unavailable, or the exporter target is missing.

Inspect: Compare exporter up and pg_up. Check database logs, endpoints, PVC capacity and credentials privately.

Recovery: Restore the database or exporter/scrape path. Verify pg_up=1, readiness, reads and preserved rows. Never delete a PVC to fix connectivity.

## DBPoolSaturated

At least 90% of the pool is in use and waits are growing for five minutes.

Inspect: Compare in-use/max connections, waits and query activity. Idle open connections are normal.

Recovery: Resolve slow/blocked queries or excess concurrency before increasing limits; account for all replicas.

## GatewayUnavailable

The cluster gateway cannot return HTTP 200 for /api/items, or its probe is unavailable.

Inspect: Check NGINX logs, API readiness, Service endpoints and database health. This checks the internal gateway, not public DNS/TLS.

Recovery: Restore the dependency or probe and verify probe_success=1 and frontend/API requests.

## PodCrashLooping

An application container restarted more than three times in fifteen minutes.

Inspect: Inspect termination reasons, previous logs and OOM/resource limits. Database outages should not restart API pods.

Recovery: Fix the crash/resource problem and confirm restart counts stop increasing; historical windows take time to clear.

## Common checks

```bash
kubectl --context="$KUBE_CONTEXT" -n "$APP_NAMESPACE" get pods,svc,endpointslices,pvc
kubectl --context="$KUBE_CONTEXT" -n "$APP_NAMESPACE" describe pod POD_NAME
kubectl --context="$KUBE_CONTEXT" -n "$APP_NAMESPACE" logs deployment/api --tail=100
kubectl --context="$KUBE_CONTEXT" -n "$APP_NAMESPACE" logs POD_NAME --previous --tail=100
```

See [monitoring setup](monitoring.md). Default notifications are disabled.
