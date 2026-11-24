#!/bin/bash
# Build the Release app and install it to /Applications (replaces the running copy). Usage: scripts/install.sh
set -o pipefail
cd "$(dirname "$0")/.."
xcodegen generate --quiet >/dev/null || exit 1
xcodebuild -project tikjot.xcodeproj -scheme tikjot -configuration Release -derivedDataPath .build/xcode-release \
  -allowProvisioningUpdates build 2>&1 | grep -E "error:|BUILD" || exit 1
APP=.build/xcode-release/Build/Products/Release/tikjot.app
# Never install a build a debugger could attach to (Release has CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO).
for B in "$APP" "$APP/Contents/PlugIns/tikjotWidget.appex"; do
  if codesign -d --entitlements - --xml "$B" 2>/dev/null | grep -q "com.apple.security.get-task-allow</key><true/>"; then
    echo "error: $B is signed with get-task-allow — not installing"; exit 1
  fi
done
pkill -f "/Applications/tikjot.app/Contents/MacOS/tikjot"   # only the installed copy
# Wait until it has quit: a second copy started too early would hand over to it and exit (single instance).
for i in $(seq 1 50); do pgrep -f "/Applications/tikjot.app/Contents/MacOS/tikjot" >/dev/null || break; sleep 0.1; done
rm -rf /Applications/tikjot.app && cp -R "$APP" /Applications/ && open /Applications/tikjot.app
