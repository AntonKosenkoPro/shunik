#!/bin/sh
# Xcode Cloud pre-xcodebuild script: SwiftLint gate (mirrors ios.yml).
#
# Runs before every Cloud xcodebuild action — PR-check builds and tag
# archives alike. Tags build from lint-green main, so the gate is a no-op
# there; PR builds fail fast here instead of after an expensive compile.
# swiftlint is intentionally NOT part of ci_post_clone.sh: lint belongs to
# the build phase it gates, and a lint failure must read as a build
# failure in Cloud's action reporting.
#
# Location caveat (PR #147 spike): the Build action runs this script from
# its repo location (ios/TimeOfLife/ci_scripts), but Test-action VMs replay
# it from a canonical <clone-root>/ci_scripts path — `dirname $0`/.. is
# NOT the project dir there. Resolve robustly via the .swiftlint.yml
# marker (adjacent first, then <git-root>/ios/TimeOfLife); when no iOS
# sources are present at all, skip quietly — the Build action already
# gated lint, and failing here would red four parallel Test runs for
# nothing.
#
# Pin (move-ios-checks-to-xcode-cloud): asserted fail-closed like xcodegen
# in ci_post_clone.sh. Bump SWIFTLINT_PIN (and docs/ci.md) with the local
# toolchain; never relax --strict to fix a version-skew failure — pin.
set -e

SWIFTLINT_PIN="0.65.1"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR=""
if [ -f "$SCRIPT_DIR/../.swiftlint.yml" ]; then
  PROJECT_DIR="$SCRIPT_DIR/.."
else
  GIT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$GIT_ROOT" ] && [ -f "$GIT_ROOT/ios/TimeOfLife/.swiftlint.yml" ]; then
    PROJECT_DIR="$GIT_ROOT/ios/TimeOfLife"
  fi
fi

if [ -z "$PROJECT_DIR" ]; then
  echo "iOS sources not present in this context — skipping SwiftLint (the Build action already gated lint)."
  exit 0
fi
cd "$PROJECT_DIR"

if ! command -v swiftlint >/dev/null 2>&1; then
  echo "swiftlint not found — installing via Homebrew..."
  brew install swiftlint
fi

echo "swiftlint $(swiftlint version)"
case "$(swiftlint version)" in
  *"$SWIFTLINT_PIN"*) ;;
  *)
    echo "error: swiftlint version drift — expected $SWIFTLINT_PIN. Bump SWIFTLINT_PIN (and docs/ci.md) if intentional."
    exit 1
    ;;
esac

swiftlint lint --strict

# Commented-out Swift gate (cleanup-dead-code-comments): `//` lines shaped like
# code are dead code — delete them. Doc `///`, `// MARK:`, and URLs stay exempt.
# Declaration alternatives require a trailing `:`/`(`/`{` and `return` anchors to
# a single token, so prose ("// return the value") never trips the build.
# Fail closed: a renamed/missing scan dir must break the build, not
# silently disable the gate below (`|| true` would swallow grep's error).
# Single source of truth for the gate's scan roots (loop + grep below must
# never drift apart). Unquoted `$scan_dirs` word-splitting is intentional.
scan_dirs="TimeOfLife LifioLiveActivities LifioLiveActivityCore TimeOfLifeTests"
for d in $scan_dirs; do
  [ -d "$d" ] || { echo "error: expected scan dir '$d' is missing — commented-code gate cannot run"; exit 1; }
done
commented_code="$(grep -rEn --include='*.swift' \
  '// ?(func [A-Za-z_]+[(]|let [A-Za-z_]+ ?[:=]|var [A-Za-z_]+ ?[:=]|class [A-Za-z_]+ ?[<(:{]|struct [A-Za-z_]+ ?[<(:{]|enum [A-Za-z_]+ ?[<(:{]|if [^{]*[{]|for [^{]*[{]|while [^{]*[{]|return [^ ]+$)' \
  $scan_dirs \
  | grep -v '///' | grep -v '// MARK:' | grep -vE 'https?://' || true)"
if [ -n "$commented_code" ]; then
  printf '%s\n' "$commented_code"
  echo "error: commented-out Swift code found — delete it or convert to /// docs"; exit 1
fi
