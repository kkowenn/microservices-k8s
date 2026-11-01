# Database outage exercise report

This is a controlled learning exercise, not a production incident. Do not treat
unit-test outcomes as proof of a real notification or full-stack deployment.

## Scope and expected behavior

In an isolated `demo-*` namespace, temporarily scale standalone PostgreSQL from
one instance to zero. Keep the database PVC. API readiness should fail while
liveness and the separate metrics listener remain available. The gateway should
stop serving items. The exporter should report `pg_up=0`.

After their hold periods, `DatabaseDown` and `GatewayUnavailable` should fire.
Restore PostgreSQL, verify identical item IDs/names and unchanged API restart
counts, then observe both alerts resolve. The default receiver sends no external
messages. Slack delivery needs a separately configured and explicitly enabled
receiver and cannot be claimed from this exercise alone.

## Verification record

Configuration checks pass for the four pinned Helm charts, discovery selectors,
provisioned dashboard, and canonical/deployed rule equivalence. All seven alert
rules have promtool fixtures, including database outage and resolution, missing
targets, high latency/error rates, pool pressure, restarts, and zero traffic.
API regressions verify metric isolation, fixed labels, JSON logs and request IDs.

The local instrumented application passed gateway/API smoke checks in
`demo-observability`. The managed workspace has an 8 GB filesystem; complete
Grafana/Alloy image pulls exhausted that capacity, so the full monitoring stack
could not be verified there. Only task-created scratch/tool images were removed
to recover space. Existing application namespaces and their database PVCs were
not deleted or upgraded. A newly created test database whose bootstrap was
interrupted by full disk was initialized after space was recovered.

The `Monitoring runtime` workflow performs the complete real-stack exercise on
relevant pushes and manual dispatch. Its job logs are the evidence for Grafana
provisioning, Loki ingestion and live alert transitions. Record its result and
URL here after execution; do not infer success from configuration validation.

## Reproduce and collect evidence

Follow [monitoring setup](monitoring.md), then run:

```bash
python3 scripts/test/test-monitoring.py
python3 scripts/monitoring/exercise.py
```

Record the environment/commit, start and recovery times, alert firing/resolution
results, API restart counts, item comparison, and workflow URL. Capture Grafana
screenshots only after the real dashboard has data; exclude credentials.

## Lessons

- Keep metrics discovery independent of application readiness.
- Monitor the gateway as well as API handlers; rejected traffic may never reach
  the API's request counter.
- Alert on missing scrape targets as well as failed scrapes.
- Test alert hold periods deliberately; a fast pod restart may not fire an alert.
- Budget image/storage capacity and test restore/recovery without deleting PVCs.
