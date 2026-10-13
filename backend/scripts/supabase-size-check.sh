#!/bin/sh
# Quota guard for Supabase Free (migrate-db-to-supabase-free): the plan flips
# read-only above 500 MB database size, so alert at 70% (~350 MB) while writes
# still succeed. Exit 0 below the line, exit 2 above it (cron treats non-zero
# as a failure to notify on). Prints sizes only — never connection details.
#
# Usage (VM cron, weekly): /opt/timeoflife/scripts/supabase-size-check.sh
# Reads DATABASE_URL from the environment (VM: `set -a; . /opt/timeoflife/.env`).
# Tool override for hosts without postgres clients (VM cron):
#   PSQL_BIN="docker run --rm postgres:15-alpine psql"
set -eu

: "${PSQL_BIN:=psql}"

: "${DATABASE_URL:?DATABASE_URL must be set (sourced from the deployment .env)}"
ALERT_MB="${ALERT_MB:-350}"

SIZE_BYTES="$($PSQL_BIN "$DATABASE_URL" -tAc "select pg_database_size(current_database())")"
SIZE_MB=$((SIZE_BYTES / 1024 / 1024))
echo "database size: ${SIZE_MB} MB (alert line: ${ALERT_MB} MB)"

if [ "$SIZE_MB" -ge "$ALERT_MB" ]; then
  echo "ALERT: database at ${SIZE_MB} MB — over the ${ALERT_MB} MB line. See the paid-tier upgrade runbook. This script alerts only — check size manually before any repoint; the repoint gate itself is the operator runbook, not this script."
  exit 2
fi
echo "OK: below the alert line."
