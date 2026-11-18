# Security policy

## Repository boundary

This repository must not contain production IP addresses, domain credentials, `.env` files, TLS private keys, TURN secrets, database dumps, attachments or diagnostic reports with personal data.

## Important tradeoffs

- Mounting `/var/run/docker.sock` gives root-equivalent control. Sozyv Ops deliberately does not mount it into long-running monitoring services.
- cAdvisor is privileged and optional. Run it only on a trusted host and keep its port private.
- Grafana, Prometheus and Alertmanager bind to loopback. Do not expose them directly to the internet.
- PostgreSQL exporter credentials should belong to a dedicated monitoring role with the smallest practical permissions.
- Configuration backups may contain secrets. Encrypt before off-site transfer.
- Restore is intentionally guarded by `CONFIRM_RESTORE`, a separate target name and an in-place restore block.

## Reporting

Do not open a public issue containing credentials, production logs or backup samples. Revoke an exposed secret before investigating how it leaked.
