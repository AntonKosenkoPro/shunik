#!/bin/sh
# Xcode Cloud post-xcodebuild script: upload dSYMs to Sentry.
#
# Runs after every Cloud xcodebuild action. Uploads only when an archive
# exists ($CI_ARCHIVE_PATH/dSYMs) — PR Test-only builds produce no archive
# and skip quietly here. Per project (staging, release) the upload runs only
# when SENTRY_AUTH_TOKEN + SENTRY_ORG + the project var are all present;
# otherwise it skips with a reason (secret values are never echoed — Cloud
# redacts secret env vars in logs regardless).
#
# sentry-cli is intentionally NOT fail-closed pinned (migrate-ios-ci-to-
# xcode-cloud D3): a leaf uploader's version skew cannot change pass/fail
# correctness, so only the version is echoed. Follows the sibling install-
# when-missing pattern from ci_post_clone.sh / ci_pre_xcodebuild.sh.
#
# Upload failures warn loudly but never fail the build (observability
# Stage 0 invariant, kept from the #156 version): a missing symbol set
# degrades crash reports; a failed archive would block TestFlight entirely.
set -e

if [ -z "$CI_ARCHIVE_PATH" ]; then
  echo "No archive produced by this build (Test-only) — skipping Sentry upload."
  exit 0
fi
if [ ! -d "$CI_ARCHIVE_PATH/dSYMs" ]; then
  echo "WARNING — no dSYMs at $CI_ARCHIVE_PATH/dSYMs; skipping Sentry upload (crashes from this build may be unsymbolicated)."
  exit 0
fi

if ! command -v sentry-cli >/dev/null 2>&1; then
  echo "sentry-cli not found — installing via Homebrew..."
  if ! brew install getsentry/tools/sentry-cli; then
    echo "WARNING — sentry-cli install failed; skipping dSYM uploads (crashes from this build will be unsymbolicated). Not failing the archive."
    exit 0
  fi
  if ! command -v sentry-cli >/dev/null 2>&1; then
    echo "WARNING — sentry-cli unavailable after install (not on PATH); skipping dSYM uploads (crashes from this build will be unsymbolicated). Not failing the archive."
    exit 0
  fi
fi

echo "sentry-cli $(sentry-cli --version)"

upload_project() {
  name="$1"; project="$2"; secret_name="$3"
  missing=""
  [ -n "$SENTRY_AUTH_TOKEN" ] || missing="SENTRY_AUTH_TOKEN"
  [ -n "$SENTRY_ORG" ] || missing="${missing:+$missing, }SENTRY_ORG"
  [ -n "$project" ] || missing="${missing:+$missing, }$secret_name"
  if [ -n "$missing" ]; then
    echo "Sentry secrets absent — skipping dSYM upload ($name). Missing: $missing."
    return 0
  fi
  if sentry-cli debug-files upload --org "$SENTRY_ORG" --project "$project" \
    "$CI_ARCHIVE_PATH/dSYMs"; then
    echo "Uploaded dSYMs ($name)."
  else
    echo "WARNING — dSYM upload failed ($name, exit $?). Crashes from this build will be unsymbolicated. Not failing the archive."
  fi
}

upload_project staging "$SENTRY_PROJECT_STAGING" SENTRY_PROJECT_STAGING
upload_project release "$SENTRY_PROJECT_RELEASE" SENTRY_PROJECT_RELEASE
