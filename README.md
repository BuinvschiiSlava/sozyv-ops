# Созыв Ops

[![validate](https://github.com/BuinvschiiSlava/sozyv-ops/actions/workflows/validate.yml/badge.svg)](https://github.com/BuinvschiiSlava/sozyv-ops/actions/workflows/validate.yml)

Monitoring, verified backups and incident diagnostics for the corporate messenger **Созыв**.

> Бэкап, который ни разу не восстанавливали, — это не бэкап, а надежда.

## Что показывает проект

- Prometheus собирает метрики Linux, Docker, PostgreSQL и HTTP/TLS;
- Grafana автоматически получает готовый русскоязычный дашборд;
- Alertmanager группирует предупреждения о недоступности, ресурсах, TLS и backup;
- PostgreSQL архивируется через `pg_dump` в custom format;
- вложения и конфигурация сохраняются отдельными архивами;
- каждый backup получает SHA-256 manifest и проверяется через `pg_restore --list`;
- restore по умолчанию разрешён только в отдельную тестовую базу;
- `doctor.sh` проверяет контейнеры, БД, volume, endpoint, диск, память, TLS и свежесть backup;
- результаты backup, restore и диагностики экспортируются в Prometheus textfile collector;
- GitHub Actions действительно поднимает PostgreSQL, создаёт backup и восстанавливает его.

```text
                     ┌──────────── Grafana
                     │
Созыв ── blackbox ── Prometheus ── Alertmanager
  │                  │   │   │
  │                  │   │   └── PostgreSQL exporter
  │                  │   └────── cAdvisor
  │                  └────────── node_exporter + textfile metrics
  │
  ├── PostgreSQL ── pg_dump ─────┐
  ├── attachments ── tar ────────┼── checksums ── restore drill
  └── configuration ── tar ──────┘
```

## Быстрый демонстрационный запуск

Нужны Docker Engine или Docker Desktop, Compose v2 и Bash. Для проверки JSON используется локальный `jq`, а при его отсутствии — контейнер с `jq`.

```bash
cp .env.example .env
./scripts/render-targets.sh
./scripts/demo-smoke.sh
```

После запуска:

- Grafana: `http://127.0.0.1:3000`;
- Prometheus: `http://127.0.0.1:9090`;
- Alertmanager: `http://127.0.0.1:9093`.

Логин Grafana и пароль берутся из `.env`. Демо-проверка создаёт PostgreSQL backup, архивирует тестовое вложение, восстанавливает БД `sozyv_restore_test`, проверяет две строки и удаляет только тестовую базу.

Остановить стенд:

```bash
docker compose --env-file .env --profile demo --profile host down
```

## Подключение к настоящему Созыву

Проект рассчитан на существующую архитектуру мессенджера:

- Java/Spring приложение с `/api/v1/health`;
- PostgreSQL 18;
- Docker volume с вложениями;
- Nginx/TLS;
- отдельный coturn для звонков.

Заполните `.env`, указав существующие Docker network и volume, затем проверьте объединённую модель:

```bash
docker compose -f compose.yaml -f compose.production.yaml config --quiet
./scripts/verify-config.sh
```

Запуск monitoring stack на Linux:

```bash
docker compose -f compose.yaml -f compose.production.yaml \
  --profile host up -d
```

Создание backup:

```bash
docker compose -f compose.yaml -f compose.production.yaml \
  --profile jobs run --rm backup
```

Восстановление сначала выполняется в отдельную базу:

```bash
BACKUP_ID=20261118T120000Z \
RESTORE_DATABASE=sozyv_restore_test \
CONFIRM_RESTORE=YES \
docker compose -f compose.yaml -f compose.production.yaml \
  --profile jobs run --rm restore
```

## Почему используются именно эти инструменты

Docker-порты и приложение проверяются Blackbox Exporter по multi-target pattern. Node Exporter собирает состояние Linux-хоста, cAdvisor — контейнеров, а postgres_exporter поддерживает PostgreSQL 18. Grafana datasource и dashboard создаются из файлов, поэтому окружение воспроизводимо и проверяется через Git.

Для БД используется custom archive: PostgreSQL рекомендует восстанавливать такой формат через `pg_restore`; он переносим и позволяет проверить каталог до восстановления.

Официальные материалы:

- [Prometheus Node Exporter guide](https://prometheus.io/docs/guides/node-exporter/)
- [Prometheus multi-target exporter pattern](https://prometheus.io/docs/guides/multi-target-exporter/)
- [Grafana provisioning](https://grafana.com/docs/grafana/latest/administration/provisioning/)
- [PostgreSQL pg_restore](https://www.postgresql.org/docs/18/app-pgrestore.html)
- [cAdvisor container deployment](https://github.com/google/cadvisor)
- [PostgreSQL exporter](https://github.com/prometheus-community/postgres_exporter)

## Документация

- [Архитектура](docs/architecture.md)
- [Backup и restore](docs/backup-and-restore.md)
- [Развёртывание рядом с Созывом](docs/production-deployment.md)
- [Incident runbook](docs/incident-runbook.md)
- [Модель безопасности](SECURITY.md)

## Важные ограничения

- Не публикуйте `.env`, архивы, TLS-ключи и логи с персональными данными.
- Доступ к Grafana, Prometheus и Alertmanager по умолчанию привязан к localhost.
- cAdvisor имеет привилегированный доступ к Docker-хосту и включается только профилем `host`.
- На сервере с небольшим объёмом RAM разумнее вынести Grafana и Prometheus на отдельный monitoring host, оставив рядом с Созывом exporters, backup и doctor.
- Перед настоящим restore сохраните текущие данные и проверьте процедуру на отдельной машине.
