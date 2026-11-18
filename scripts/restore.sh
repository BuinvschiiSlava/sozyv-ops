#!/bin/sh
set -eu

umask 077

require_value() {
  name=$1
  eval "value=\${$name:-}"
  if [ -z "$value" ]; then
    printf 'Required environment variable is empty: %s\n' "$name" >&2
    exit 1
  fi
}

for name in POSTGRES_HOST POSTGRES_PORT POSTGRES_DB POSTGRES_ADMIN_USER POSTGRES_ADMIN_PASSWORD BACKUP_ID RESTORE_DATABASE; do
  require_value "$name"
done

case "$BACKUP_ID" in
  20??????T??????Z) ;;
  *) printf 'BACKUP_ID must look like 20261118T210000Z.\n' >&2; exit 1 ;;
esac

case "$RESTORE_DATABASE" in
  *[!a-zA-Z0-9_]*) printf 'RESTORE_DATABASE may contain only letters, numbers and underscores.\n' >&2; exit 1 ;;
esac

if [ "$CONFIRM_RESTORE" != YES ]; then
  printf 'Restore is blocked. Set CONFIRM_RESTORE=YES after reviewing the target.\n' >&2
  exit 2
fi

if [ "$RESTORE_DATABASE" = "$POSTGRES_DB" ] && [ "${ALLOW_IN_PLACE_RESTORE:-NO}" != YES ]; then
  printf 'In-place restore into %s is blocked. Use a separate verification database.\n' "$POSTGRES_DB" >&2
  exit 2
fi

BACKUP_PATH="/backups/$BACKUP_ID"
if [ ! -d "$BACKUP_PATH" ]; then
  printf 'Backup does not exist: %s\n' "$BACKUP_PATH" >&2
  exit 1
fi

(
  cd "$BACKUP_PATH"
  sha256sum -c SHA256SUMS
)
pg_restore --list "$BACKUP_PATH/database.dump" >/dev/null

export PGPASSWORD="$POSTGRES_ADMIN_PASSWORD"
admin_database=postgres
exists=$(psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_ADMIN_USER" -d "$admin_database" -Atc \
  "SELECT 1 FROM pg_database WHERE datname = '$RESTORE_DATABASE';")

if [ "$exists" = 1 ]; then
  if [ "${DROP_RESTORE_DATABASE:-NO}" != YES ]; then
    printf 'Target database already exists. Set DROP_RESTORE_DATABASE=YES only for a disposable target.\n' >&2
    exit 2
  fi
  psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_ADMIN_USER" -d "$admin_database" -v ON_ERROR_STOP=1 -c \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$RESTORE_DATABASE' AND pid <> pg_backend_pid();" >/dev/null
  dropdb -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_ADMIN_USER" "$RESTORE_DATABASE"
fi

createdb -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_ADMIN_USER" "$RESTORE_DATABASE"
pg_restore \
  --host="$POSTGRES_HOST" \
  --port="$POSTGRES_PORT" \
  --username="$POSTGRES_ADMIN_USER" \
  --dbname="$RESTORE_DATABASE" \
  --no-owner \
  --no-acl \
  --exit-on-error \
  "$BACKUP_PATH/database.dump"

table_count=$(psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_ADMIN_USER" -d "$RESTORE_DATABASE" -Atc \
  "SELECT count(*) FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog','information_schema');")

if [ "${RESTORE_ATTACHMENTS:-NO}" = YES ]; then
  if find /restore/attachments -mindepth 1 -print -quit | grep -q .; then
    printf 'Attachment restore directory is not empty; refusing to overwrite it.\n' >&2
    exit 2
  fi
  tar -C /restore/attachments -xzf "$BACKUP_PATH/attachments.tar.gz"
fi

mkdir -p /metrics
metric_tmp="/metrics/.sozyv_restore.prom.$$"
cat > "$metric_tmp" <<EOF
# HELP sozyv_restore_last_success_timestamp_seconds Unix timestamp of the latest successful restore drill.
# TYPE sozyv_restore_last_success_timestamp_seconds gauge
sozyv_restore_last_success_timestamp_seconds $(date +%s)
# HELP sozyv_restore_last_table_count Number of restored user tables.
# TYPE sozyv_restore_last_table_count gauge
sozyv_restore_last_table_count $table_count
EOF
chmod 0644 "$metric_tmp"
mv "$metric_tmp" /metrics/sozyv_restore.prom

printf 'Restore verification completed.\n'
printf '  backup: %s\n' "$BACKUP_ID"
printf '  target database: %s\n' "$RESTORE_DATABASE"
printf '  restored user tables: %s\n' "$table_count"
printf 'Configuration archive was verified but not applied automatically.\n'
