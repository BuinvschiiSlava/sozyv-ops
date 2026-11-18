# Incident runbook

## First five minutes

1. Record the alert time and affected component.
2. Run `scripts/doctor.sh`; keep its output.
3. Check `docker ps` and `docker stats --no-stream`.
4. Read logs with a bounded tail: `docker logs --tail 200 CONTAINER`.
5. Check disk and memory before restarting anything.

## Messenger endpoint is down

- Confirm whether Nginx, the Java application or PostgreSQL is failing.
- Test the internal application health endpoint from its Docker network.
- Check certificate expiry and Nginx configuration with `nginx -t` inside the proxy container.
- Restart only the failed service after capturing its logs.

## PostgreSQL is unavailable

- Check filesystem free space and PostgreSQL logs.
- Do not remove a volume or run `docker compose down -v`.
- If corruption is suspected, stop writes and preserve the volume before attempting recovery.
- Restore into a separate database or host first.

## Backup is stale or failed

- Keep the previous successful directory untouched.
- Inspect job output, destination free space and database connectivity.
- Run a manual backup.
- Validate `SHA256SUMS` and perform a restore drill.

## Container restart loop

- Capture inspect data and the last 200 log lines.
- Check exit code, OOM status and mounted paths.
- Compare the running image tag and configuration with the last known working release.
- Roll back the application image without deleting PostgreSQL or attachment volumes.

## Recovery is complete when

- the public and internal health checks are stable;
- PostgreSQL accepts queries;
- users can authenticate and exchange a test message;
- the current alert is resolved;
- a fresh backup succeeds;
- the timeline and root cause are documented.
