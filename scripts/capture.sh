#!/bin/bash
# scripts/capture.sh <name> <target: popover|main|settings|onboarding> [extra args…]
# Renders the demo app (debug build) to /private/tmp/tikjot-captures/<name>.png.
cd "$(dirname "$0")/.."
NAME=$1; TARGET=$2; shift 2
DIR=/private/tmp/tikjot-captures; mkdir -p $DIR
rm -f "$DIR/$NAME.png"
pkill -f "Debug/tikjot.app/Contents/MacOS/tikjot" 2>/dev/null; sleep 0.5   # only the dev build — never your everyday tikjot
OPEN=""
case $TARGET in window) OPEN="";; popwin) OPEN=-openMain;; popover) OPEN=-openPopover;; main|sheet) OPEN=-openMain;; settings) OPEN=-openSettings;; onboarding) OPEN=-openOnboarding;; esac
open -g -n .build/xcode/Build/Products/Debug/tikjot.app --args -tikjotDemo $OPEN -capture $TARGET $NAME.png -captureQuit "$@"
for i in $(seq 1 30); do [ -f "$DIR/$NAME.png" ] && break; sleep 0.5; done
sleep 0.3
[ -f "$DIR/$NAME.png" ] && echo "$DIR/$NAME.png" || echo "capture failed"
