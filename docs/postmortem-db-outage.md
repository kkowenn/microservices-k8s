# Database Outage Exercise

This is a local failure-recovery test, not a production incident.

## Objective

Simulate a PostgreSQL outage and verify that monitoring detects the failure and the application recovers without data loss.

Expected behavior:

- Scale PostgreSQL from 1 to 0 replicas without deleting its PVC.
- API readiness fails, but liveness and `/metrics` remain available.
- Gateway requests fail and PostgreSQL exporter reports `pg_up=0`.
- `DatabaseDown` and `GatewayUnavailable` alerts fire after their configured hold periods.
- Restore PostgreSQL and confirm that alerts resolve, data remains unchanged, and API restart counts do not increase.

External notifications are disabled by default.

## Test Results

| Test | Result |
|---|---|
| Helm chart and configuration validation | Passed |
| Alert rules and promtool tests | Passed |
| API metrics and logging tests | Passed |
| Application smoke tests | Passed |
| Full monitoring stack deployment | Not completed |
| Live alert firing and recovery | Not verified |

The application passed smoke tests in `demo-observability`.

However, the test environment had only 8 GB of disk space. Grafana and Alloy image pulls exhausted the available storage, preventing full-stack validation.

Existing application PVCs were preserved. A new test database with an interrupted initialization was recovered after freeing disk space.

The `Monitoring runtime` GitHub Actions workflow is configured to run the full exercise. Its results still need to be checked.

## Reproduce

Follow [monitoring setup](monitoring.md), then run:

```bash
python3 scripts/test/test-monitoring.py
python3 scripts/monitoring/exercise.py
```

Run the outage exercise only in an isolated test namespace.

Record the commit, test times, alert states, API restart counts, database item comparison, and GitHub Actions workflow URL.

## Lessons Learned

- Keep metrics available even when the application is unhealthy.
- Monitor gateway availability, not just API metrics.
- Detect missing scrape targets as well as failed scrapes.
- Account for alert hold periods when testing outages.
- Allocate enough disk space for monitoring images and persistent storage.
- Verify database recovery without deleting PVCs.

## CI Evidence

**Workflow:** `Monitoring runtime`  
**Status:** Pending verification  
**Workflow URL:** To be added after execution

See [monitoring setup](monitoring.md) for installation and configuration.