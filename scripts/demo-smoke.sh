#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

[[ -f .env ]] || cp .env.example .env
./scripts/render-targets.sh

docker compose --env-file .env --profile demo up -d --wait demo-postgres demo-app
docker compose --env-file .env --profile demo run --rm demo-seed
if [[ "${SKIP_MONITORING:-no}" != yes ]]; then
  docker compose --env-file .env up -d postgres-exporter blackbox-exporter alertmanager prometheus grafana
fi

docker compose --env-file .env --profile jobs run --rm backup
backup_id=$(docker compose --env-file .env --profile jobs run --rm --entrypoint sh backup \
  -c 'tr -d "\r\n" < /backups/latest.txt')

BACKUP_ID="${backup_id}" \
RESTORE_DATABASE=sozyv_restore_test \
CONFIRM_RESTORE=YES \
DROP_RESTORE_DATABASE=YES \
docker compose --env-file .env --profile jobs run --rm restore

row_count=$(docker compose --env-file .env exec -T demo-postgres \
  psql -U postgres -d sozyv_restore_test -Atc 'SELECT count(*) FROM demo_message;')
[[ "${row_count}" == 2 ]]

docker compose --env-file .env --profile jobs run --rm --entrypoint sh \
  -e BACKUP_ID="${backup_id}" backup -c \
  'cd "/backups/${BACKUP_ID}" && sha256sum -c SHA256SUMS && tar -tzf attachments.tar.gz | grep -q demo-message.txt'

docker compose --env-file .env exec -T demo-postgres dropdb -U postgres sozyv_restore_test

printf 'Demo smoke test passed. Backup %s restored two database rows and one attachment.\n' "${backup_id}"
