#!/bin/sh
# Xcode Cloud post-clone script (PR checks + tag archives).
#
# The .xcodeproj is gitignored (XcodeGen-managed: edit project.yml, then
# `xcodegen generate`), so generate it here before Xcode Cloud builds.
# SwiftPM dependencies (GRDB) resolve automatically during the build.
#
# Toolchain pins (move-ios-checks-to-xcode-cloud): versions are asserted
# fail-closed after install — a drifted Homebrew bottle fails the build
# loudly instead of checking with the wrong toolchain. Bump the pins here
# (and in docs/ci.md) when the local toolchain moves.
set -e

cd "$(dirname "$0")/.."

XCODEGEN_PIN="2.46.0"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen not found — installing via Homebrew..."
  brew install xcodegen
fi

echo "xcodegen $(xcodegen --version)"
case "$(xcodegen --version)" in
  *"$XCODEGEN_PIN"*) ;;
  *)
    echo "error: xcodegen version drift — expected $XCODEGEN_PIN. Bump XCODEGEN_PIN (and docs/ci.md) if intentional."
    exit 1
    ;;
esac

xcodegen generate

# The generate must yield a usable project (postGenCommand
# normalize-system-capabilities.py runs as part of it).
if [ ! -d "Shunik.xcodeproj" ]; then
  echo "error: xcodegen generate produced no Shunik.xcodeproj."
  exit 1
fi
