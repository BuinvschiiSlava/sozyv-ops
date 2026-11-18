# Architecture

Sozyv Ops separates four concerns so that a failed dashboard cannot damage the messenger and a failed backup cannot replace the previous valid archive.

```text
                          +----------------------+
                          | Grafana              |
                          | provisioned dashboard|
                          +----------+-----------+
                                     |
                                     v
+---------------+       +------------+-----------+       +------------------+
| Sozyv /health |------>| Prometheus             |------>| Alertmanager     |
| HTTPS endpoint| probe | rules and time series  |       | routing and UI   |
+-------+-------+       +---+----------+---------+       +------------------+
        |                   |          |
        |              node_exporter   +---- postgres_exporter
        |              cAdvisor
        |
        +---- Spring application ---- PostgreSQL
                 |                         |
                 +---- attachments         +---- pg_dump custom archive
                           |                         |
                           +----------- backup job -+
                                         |
                              checksums + metrics + restore drill
```

## Trust boundaries

- Grafana, Prometheus and Alertmanager bind to localhost by default.
- The monitoring network does not publish exporter ports.
- The backup container receives read-only access to attachments and configuration.
- The restore job refuses an in-place restore unless an explicit override is supplied.
- cAdvisor is optional because its privileged host access is a real security tradeoff.
- Generated backup archives and Prometheus textfile metrics are excluded from Git.

## Production connection

`compose.production.yaml` attaches the jobs and PostgreSQL exporter to the existing Sozyv network and attachment volume. Their exact names are configured in `.env`; no production address is committed to the repository.
