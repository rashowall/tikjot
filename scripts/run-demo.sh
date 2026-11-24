#!/bin/bash
# Launch the built app in demo mode. Extra args are passed through (e.g. -openPopover, -openMain).
cd "$(dirname "$0")/.."
pkill -f "Debug/tikjot.app/Contents/MacOS/tikjot" 2>/dev/null; sleep 0.5   # only the dev build — never your everyday tikjot
open -n .build/xcode/Build/Products/Debug/tikjot.app --args -tikjotDemo "$@"
