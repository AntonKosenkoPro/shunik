#!/bin/sh
# Weekly pg_dump of the hosted relay database (Supabase Free has no automated
# backups — migrate-db-to-supabase-free, backup floor).
#
# Usage (VM cron): 0 3 * * 0 /opt/timeoflife/scripts/supabase-backup.sh /var/backups/supabase
# Reads DATABASE_URL from the environment (VM: `set -a; . /opt/timeoflife/.env`).
# Off-site leg (spec backend-database: >=30d retention outside this VM and the
# DB project): set BACKUP_BUCKET=gs://<bucket> (VM has gsutil); the transfer
# then runs on every backup and Cron activation REQUIRES the bucket set —
# without it dumps are VM-local only. Bucket creation is operator one-time setup.
# Tool override for hosts without postgres clients (VM cron):
#   PGDUMP_BIN="docker run --rm postgres:17-alpine pg_dump"  (must dump to STDOUT)
# Pin the image major to the DB's major version: pg_dump cannot dump a newer
# server (e.g. pg_dump 15 aborts with "server version mismatch" against the
# Supabase PG17 project). Re-pin when the DB major changes.
# RETENTION_DAYS (default 30): prune threshold for local artifacts.
case "${RETENTION_DAYS:-30}" in
  *[!0-9]*) echo "ERROR: RETENTION_DAYS must be a non-negative integer, got '${RETENTION_DAYS:-}'" >&2; exit 2 ;;
esac
[ "${RETENTION_DAYS:-30}" -ge 30 ] || echo "WARNING: RETENTION_DAYS=${RETENTION_DAYS:-30} is below the spec's 30-day retention floor" >&2
RETENTION_DAYS="${RETENTION_DAYS:-30}" # assign once: later bare uses run under `set -u`
# Never prints connection strings or secrets: no `set -x`, errors are redacted to host/port only.
set -eu
umask 077 # never leave partial dumps world-readable if a run aborts before chmod

: "${PGDUMP_BIN:=pg_dump}"

OUT_DIR="${1:?usage: $0 <output-dir>}"
# (RETENTION_DAYS already validated + defaulted in the early block above,
# which must run before `set -u`; no re-default here to avoid drift.)
: "${DATABASE_URL:?DATABASE_URL must be set (sourced from the deployment .env)}"

mkdir -p "$OUT_DIR"
TS="$(date +%Y%m%d-%H%M%S)"
DUMP="$OUT_DIR/supabase-$TS.sql"
SHA="$DUMP.sha256"

# --no-owner/--no-privileges: roles differ between Supabase and any restore target.
$PGDUMP_BIN "$DATABASE_URL" --no-owner --no-privileges > "$DUMP"
# Basename path so `sha256sum -c` verifies in any directory holding the artifact
# pair (VM dir, or a scratch dir after downloading the off-site copy); a failing
# sha256sum aborts the run here (POSIX sh has no pipefail to catch pipes).
( cd "$OUT_DIR" && sha256sum "$(basename "$DUMP")" ) > "$SHA"
chmod 600 "$DUMP" "$SHA"

# Off-site leg (see header): mandatory once the cron activates.
if [ -n "${BACKUP_BUCKET:-}" ]; then
  # Bucket must be private (uniform bucket-level access, no public readers):
  # it holds full database dumps, and 600 perms do not carry over to GCS.
  gsutil -m cp "$DUMP" "$SHA" "$BACKUP_BUCKET/"
else
  echo "WARNING: BACKUP_BUCKET unset — artifacts are VM-local only (spec requires off-site; set the bucket when activating the cron)" >&2
  # Cron notifies on non-zero exit only, so a missing bucket must fail the run
  # (not just warn); one-off pre-activation drills set BACKUP_LOCAL_ONLY_OK=1.
  [ "${BACKUP_LOCAL_ONLY_OK:-0}" = "1" ] || exit 2
fi

# Prune artifacts older than the retention window (mtime-based).
find "$OUT_DIR" -maxdepth 1 -name 'supabase-*.sql' -mtime +"$RETENTION_DAYS" -delete
find "$OUT_DIR" -maxdepth 1 -name 'supabase-*.sql.sha256' -mtime +"$RETENTION_DAYS" -delete

echo "backup complete: $(basename "$DUMP") ($(wc -c < "$DUMP") bytes, sha256 recorded)"
