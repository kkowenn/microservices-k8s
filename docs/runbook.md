# Application Alert Runbooks

Quick troubleshooting guide for application and database alerts.

Always use the correct Kubernetes context and namespace. Start with read-only checks and avoid exposing credentials in logs or screenshots.

## Alert Reference

| Alert | Trigger | What to check |
|---|---|---|
| **APIDown** | API metrics target down or missing | Pods, Service endpoints, ServiceMonitor, NetworkPolicy |
| **APIHighErrorRate** | Error rate >5% for 5m | API error logs, request IDs, database health, pool waits |
| **APIHighLatencyP95** | p95 latency >300ms for 10m | Slow queries, locks, CPU throttling, traffic |
| **DatabaseDown** | PostgreSQL/exporter down or target missing | `up`, `pg_up`, database logs, PVC, credentials |
| **DBPoolSaturated** | Pool usage ≥90% with growing waits for 5m | Active connections, waits, slow queries |
| **GatewayUnavailable** | `/api/items` probe fails or is missing | NGINX, API readiness, endpoints, database |
| **PodCrashLooping** | >3 restarts in 15m | Previous logs, OOMKilled, resource limits |

## Recovery

- **API / Gateway:** Restore the failing process, dependency, or scrape path. Verify gateway requests and monitoring targets.
- **High errors / latency:** Fix the underlying issue and confirm that error rates and latency return to normal.
- **Database:** Restore PostgreSQL or its exporter. Confirm `pg_up=1`, API readiness, and preserved data. Never delete PVCs to fix connectivity.
- **DB pool:** Resolve blocked queries or excessive concurrency before increasing pool limits.
- **Pod restarts:** Fix the crash or resource issue and confirm restart counts stop increasing.

Alerts with time windows may take a few minutes to resolve after recovery.

## Common Checks

```bash id="qvk6n4"
kubectl --context="$KUBE_CONTEXT" -n "$APP_NAMESPACE" get pods,svc,endpointslices,pvc
kubectl --context="$KUBE_CONTEXT" -n "$APP_NAMESPACE" describe pod POD_NAME
kubectl --context="$KUBE_CONTEXT" -n "$APP_NAMESPACE" logs deployment/api --tail=100
kubectl --context="$KUBE_CONTEXT" -n "$APP_NAMESPACE" logs POD_NAME --previous --tail=100
```

See [monitoring setup](monitoring.md) for installation and configuration.

**Note:** External alert notifications are disabled by default.