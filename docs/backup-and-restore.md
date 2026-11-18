# Backup and restore

## Backup contents

Every successful directory contains:

- `database.dump` — a PostgreSQL custom-format archive;
- `database.contents` — the `pg_restore --list` catalogue;
- `attachments.tar.gz` — uploaded files;
- `config.tar.gz` — the selected runtime configuration directory;
- `metadata.json` — timestamp-independent metadata;
- `SHA256SUMS` — checksums verified before the backup is published.

The job writes into `.partial-TIMESTAMP` first. Only after `pg_restore --list` and checksum validation succeed is it renamed to the final UTC timestamp. A failed run therefore cannot replace the previous valid backup.

## Create a backup

```bash
docker compose -f compose.yaml -f compose.production.yaml \
  --profile jobs run --rm backup
```

Automatic deletion is disabled by default. Set `PRUNE_OLD_BACKUPS=true` only after the destination path and retention policy have been reviewed.

## Restore drill

Always restore into a new disposable database first:

```bash
BACKUP_ID=20261118T120000Z \
RESTORE_DATABASE=sozyv_restore_test \
CONFIRM_RESTORE=YES \
docker compose -f compose.yaml -f compose.production.yaml \
  --profile jobs run --rm restore
```

If the disposable target already exists, add `DROP_RESTORE_DATABASE=YES`. The restore job blocks the production database name unless `ALLOW_IN_PLACE_RESTORE=YES` is also supplied.

Attachments are not extracted by default. Database verification should finish first. To extract them into the dedicated restore volume, set `RESTORE_ATTACHMENTS=YES`.

## Off-site copy

Backups can contain messages, personal data, encrypted attachment keys and TLS configuration. Encrypt the completed timestamp directory before transferring it to object storage or another host. Keep the encryption key outside both the server and this repository.

A backup is considered useful only after a restore drill has succeeded and the result has been checked at application level.
