#!/bin/bash
# Build (and optionally test) the app quietly.
# Usage: scripts/build.sh [build|test|test-unit|test-ui]
#   test        app unit + snapshot tests (hosted in the app) and UI tests (XCUITest — needs a logged-in GUI session)
#   test-unit   app unit + snapshot tests only
#   test-ui     UI tests only
# SNAPSHOT_RECORD=1 scripts/build.sh test-unit   re-records every snapshot reference.
# New / re-recorded references are copied into AppTests/__Snapshots__ (the sandboxed test host writes them to
# /private/tmp/tikjot-captures/snapshots/recorded); mismatches leave *-actual.png / *-diff.png in …/snapshots/failures.
set -o pipefail
cd "$(dirname "$0")/.."
xcodegen generate --quiet >/dev/null || exit 1
ACTION=${1:-build}
EXTRA=()
case $ACTION in
  test-unit) ACTION=test; EXTRA=(-only-testing:tikjotTests) ;;
  test-ui) ACTION=test; EXTRA=(-only-testing:tikjotUITests) ;;
esac
SNAP=/private/tmp/tikjot-captures/snapshots
if [ "$ACTION" = test ]; then
  rm -rf "$SNAP"
  # xcodebuild hands TEST_RUNNER_* variables to the test host (without the prefix).
  [ "$SNAPSHOT_RECORD" = 1 ] && export TEST_RUNNER_SNAPSHOT_RECORD=1
fi
xcodebuild -project tikjot.xcodeproj -scheme tikjot -configuration Debug -derivedDataPath .build/xcode \
  -allowProvisioningUpdates "$ACTION" "${EXTRA[@]}" 2>&1 \
  | grep -E "error:|warning: .*(Swift|deprecated)|\*\* (BUILD|TEST)|Test Case .*failed|Executed|Test run with|recorded an issue|no reference yet|pixels differ|≠ reference|rendering failed" \
  | grep -v "^\s*$" | awk 'NR <= 200'
STATUS=${PIPESTATUS[0]}
if [ "$ACTION" = test ]; then
  if ls "$SNAP/recorded/"*.png >/dev/null 2>&1; then
    cp "$SNAP/recorded/"*.png AppTests/__Snapshots__/
    echo "Recorded $(ls "$SNAP/recorded/"*.png | wc -l | tr -d ' ') snapshot reference(s) into AppTests/__Snapshots__ — review and commit them."
  fi
  [ -d "$SNAP/failures" ] && echo "Snapshot differences: $SNAP/failures"
fi
exit $STATUS
