#!/bin/sh
# Xcode Cloud post-xcodebuild script: upload dSYMs to Sentry.
#
# Why this exists (observability Stage 0, 5.2b): App Store Connect has not
# offered downloadable dSYMs since Xcode 14, so no Sentry integration can
# pull them — the archive's own builder must push them. The GitHub
# `sentry-dsym` job covers locally-archived binaries only (different UUIDs);
# Cloud-built TestFlight binaries are covered here.
#
# Runs after EVERY Cloud xcodebuild (PR checks included): PR builds produce
# no archive, so the script exits quietly when $CI_ARCHIVE_PATH is absent.
# Upload failures warn loudly but never fail the build — a missing symbol
# set degrades crash reports; a failed archive blocks TestFlight entirely.
# (The GitHub sentry-dsym job stays the loud gate for local archives.)
#
# Required Xcode Cloud workflow env vars (all three, or the upload skips):
#   SENTRY_AUTH_TOKEN — personal/org token with Project write (debug files)
#   SENTRY_ORG        — org slug
#   SENTRY_PROJECT    — project slug for this workflow's builds (staging)
# SENTRY_DSN is NOT needed here (reporting uses the app's own plist value).
set -e

if [ -z "${CI_ARCHIVE_PATH:-}" ] || [ ! -d "$CI_ARCHIVE_PATH" ]; then
  echo "sentry-dsym: no archive produced by this build (PR check?) — skipping."
  exit 0
fi

if [ -z "${SENTRY_AUTH_TOKEN:-}" ] || [ -z "${SENTRY_ORG:-}" ] || [ -z "${SENTRY_PROJECT:-}" ]; then
  echo "sentry-dsym: WARNING — SENTRY_AUTH_TOKEN/SENTRY_ORG/SENTRY_PROJECT not all set; skipping dSYM upload (crashes from this build will be unsymbolicated)."
  exit 0
fi

if ! command -v sentry-cli >/dev/null 2>&1; then
  echo "sentry-cli not found — installing via Homebrew..."
  brew install getsentry/tools/sentry-cli
fi
echo "sentry-cli $(sentry-cli --version)"

if sentry-cli debug-files upload --org "$SENTRY_ORG" --project "$SENTRY_PROJECT" "$CI_ARCHIVE_PATH/dSYMs"; then
  echo "sentry-dsym: upload complete."
else
  echo "sentry-dsym: WARNING — upload failed (exit $?). This build's crashes will be unsymbolicated; the GitHub sentry-dsym job remains the loud gate. Not failing the archive."
  exit 0
fi
