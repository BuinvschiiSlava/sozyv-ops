#!/bin/sh
set -eu

umask 077

BACKUP_ROOT=/backups
METRICS_ROOT=/metrics
LOCK_DIR=/tmp/sozyv-backup.lock
PARTIAL_DIR=
SUCCESS=0

require_value() {
  name=$1
  eval "value=\${$name:-}"
  if [ -z "$value" ]; then
    printf 'Required environment variable is empty: %s\n' "$name" >&2
    exit 1
  fi
}

write_failure_metrics() {
  mkdir -p "$METRICS_ROOT"
  tmp="$METRICS_ROOT/.sozyv_backup.prom.$$"
  if [ -f "$METRICS_ROOT/sozyv_backup.prom" ]; then
    grep -E '^sozyv_backup_(last_success_timestamp_seconds|size_bytes|attachment_files)' \
      "$METRICS_ROOT/sozyv_backup.prom" > "$tmp" || true
  else
    : > "$tmp"
  fi
  {
    printf '# HELP sozyv_backup_last_run_success Whether the latest backup attempt succeeded.\n'
    printf '# TYPE sozyv_backup_last_run_success gauge\n'
    printf 'sozyv_backup_last_run_success 0\n'
    printf '# HELP sozyv_backup_last_run_timestamp_seconds Unix timestamp of the latest backup attempt.\n'
    printf '# TYPE sozyv_backup_last_run_timestamp_seconds gauge\n'
    printf 'sozyv_backup_last_run_timestamp_seconds %s\n' "$(date +%s)"
  } >> "$tmp"
  chmod 0644 "$tmp"
  mv "$tmp" "$METRICS_ROOT/sozyv_backup.prom"
}

cleanup() {
  status=$?
  trap - EXIT HUP INT TERM
  if [ "$SUCCESS" -ne 1 ]; then
    [ -z "$PARTIAL_DIR" ] || rm -rf -- "$PARTIAL_DIR"
    write_failure_metrics || true
  fi
  rmdir "$LOCK_DIR" 2>/dev/null || true
  exit "$status"
}
trap cleanup EXIT HUP INT TERM

for name in POSTGRES_HOST POSTGRES_PORT POSTGRES_DB POSTGRES_ADMIN_USER POSTGRES_ADMIN_PASSWORD; do
  require_value "$name"
done

case "$BACKUP_ROOT" in
  /|"") printf 'Unsafe backup root: %s\n' "$BACKUP_ROOT" >&2; exit 1 ;;
esac

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  printf 'Another backup job is already running.\n' >&2
  exit 1
fi

mkdir -p "$BACKUP_ROOT" "$METRICS_ROOT"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
PARTIAL_DIR="$BACKUP_ROOT/.partial-$stamp"
FINAL_DIR="$BACKUP_ROOT/$stamp"

if [ -e "$PARTIAL_DIR" ] || [ -e "$FINAL_DIR" ]; then
  printf 'Backup path already exists for timestamp %s.\n' "$stamp" >&2
  exit 1
fi
mkdir "$PARTIAL_DIR"

export PGPASSWORD="$POSTGRES_ADMIN_PASSWORD"

ready=0
attempt=1
while [ "$attempt" -le 30 ]; do
  if pg_isready -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_ADMIN_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; then
    ready=1
    break
  fi
  attempt=$((attempt + 1))
  sleep 2
done
if [ "$ready" -ne 1 ]; then
  printf 'PostgreSQL did not become ready within 60 seconds.\n' >&2
  exit 1
fi

printf 'Creating PostgreSQL custom-format archive...\n'
pg_dump \
  --host="$POSTGRES_HOST" \
  --port="$POSTGRES_PORT" \
  --username="$POSTGRES_ADMIN_USER" \
  --dbname="$POSTGRES_DB" \
  --format=custom \
  --compress=6 \
  --no-owner \
  --no-acl \
  --file="$PARTIAL_DIR/database.dump"

pg_restore --list "$PARTIAL_DIR/database.dump" > "$PARTIAL_DIR/database.contents"

printf 'Archiving attachments and configuration...\n'
tar -C /source/attachments -czf "$PARTIAL_DIR/attachments.tar.gz" .
tar -C /source/config -czf "$PARTIAL_DIR/config.tar.gz" .

attachment_files=$(find /source/attachments -type f | wc -l | tr -d ' ')
cat > "$PARTIAL_DIR/metadata.json" <<EOF
{
  "schema_version": 1,
  "created_at_utc": "$stamp",
  "database": "$POSTGRES_DB",
  "database_format": "pg_dump custom",
  "attachment_files": $attachment_files
}
EOF

(
  cd "$PARTIAL_DIR"
  sha256sum database.dump database.contents attachments.tar.gz config.tar.gz metadata.json > SHA256SUMS
  sha256sum -c SHA256SUMS >/dev/null
)

mv "$PARTIAL_DIR" "$FINAL_DIR"
PARTIAL_DIR=

latest_tmp="$BACKUP_ROOT/.latest.$$"
printf '%s\n' "$stamp" > "$latest_tmp"
mv "$latest_tmp" "$BACKUP_ROOT/latest.txt"

backup_size_bytes=$(du -sk "$FINAL_DIR" | awk '{print $1 * 1024}')
metric_tmp="$METRICS_ROOT/.sozyv_backup.prom.$$"
cat > "$metric_tmp" <<EOF
# HELP sozyv_backup_last_run_success Whether the latest backup attempt succeeded.
# TYPE sozyv_backup_last_run_success gauge
sozyv_backup_last_run_success 1
# HELP sozyv_backup_last_run_timestamp_seconds Unix timestamp of the latest backup attempt.
# TYPE sozyv_backup_last_run_timestamp_seconds gauge
sozyv_backup_last_run_timestamp_seconds $(date +%s)
# HELP sozyv_backup_last_success_timestamp_seconds Unix timestamp of the latest successful backup.
# TYPE sozyv_backup_last_success_timestamp_seconds gauge
sozyv_backup_last_success_timestamp_seconds $(date +%s)
# HELP sozyv_backup_size_bytes Size of the latest successful backup.
# TYPE sozyv_backup_size_bytes gauge
sozyv_backup_size_bytes $backup_size_bytes
# HELP sozyv_backup_attachment_files Number of attachment files in the latest backup.
# TYPE sozyv_backup_attachment_files gauge
sozyv_backup_attachment_files $attachment_files
EOF
chmod 0644 "$metric_tmp"
mv "$metric_tmp" "$METRICS_ROOT/sozyv_backup.prom"

if [ "${PRUNE_OLD_BACKUPS:-false}" = true ]; then
  case "${RETENTION_DAYS:-14}" in
    ''|*[!0-9]*) printf 'RETENTION_DAYS must be a non-negative integer.\n' >&2; exit 1 ;;
  esac
  find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '20??????T??????Z' \
    -mtime "+${RETENTION_DAYS:-14}" -print | while IFS= read -r old_backup; do
      case "$old_backup" in
        "$BACKUP_ROOT"/20??????T??????Z) rm -rf -- "$old_backup" ;;
        *) printf 'Refusing to prune unexpected path: %s\n' "$old_backup" >&2; exit 1 ;;
      esac
    done
fi

SUCCESS=1
printf 'Backup completed: %s\n' "$FINAL_DIR"
printf 'Archive size: %s bytes; attachment files: %s\n' "$backup_size_bytes" "$attachment_files"
