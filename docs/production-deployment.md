# Production deployment

## 1. Discover names without changing the server

```bash
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
docker network ls
docker volume ls
docker inspect sozyv-app --format '{{json .NetworkSettings.Networks}}'
docker inspect sozyv-app --format '{{json .Mounts}}'
```

Record the existing Compose network, PostgreSQL hostname, attachment volume and configuration directory.

## 2. Configure

```bash
cp .env.example .env
chmod 600 .env
./scripts/render-targets.sh
```

Replace the demo database values, `SOZYV_HEALTH_URL`, `SOZYV_NETWORK_NAME`, `SOZYV_FILES_VOLUME` and `SOZYV_CONFIG_DIR`. Generate new Grafana and exporter passwords; never reuse an application password in a public example.

## 3. Validate before startup

```bash
docker compose -f compose.yaml -f compose.production.yaml config --quiet
./scripts/verify-config.sh
```

## 4. Start monitoring

```bash
docker compose -f compose.yaml -f compose.production.yaml \
  --profile host up -d prometheus grafana alertmanager blackbox-exporter \
  postgres-exporter node-exporter cadvisor
```

Grafana is available only on `127.0.0.1:3000`. Reach it through an SSH tunnel or an authenticated private reverse proxy.

On a low-memory messenger host, run backup and diagnostics there but place Prometheus and Grafana on a separate monitoring machine. Do not add the full stack until memory and disk headroom have been measured.

## 5. Install timers

```bash
sudo cp systemd/sozyv-*.service systemd/sozyv-*.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now sozyv-backup.timer sozyv-doctor.timer
systemctl list-timers 'sozyv-*'
```

Before enabling the backup timer, run one manual backup and one restore drill.
