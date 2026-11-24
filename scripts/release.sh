#!/bin/bash
# Build a release: Developer ID app (notarized + stapled) → DMG (signed, notarized, stapled) → Sparkle appcast.
# Usage: scripts/release.sh <version>        e.g. scripts/release.sh 0.9.1
# Output in dist/<version>/ (gitignored): tikjot-<version>.dmg, appcast.xml, notarization logs. Uploads nothing.
# Needs on this Mac: the "Developer ID Application" certificate (team UPB9VSQ76D), the notarytool keychain profile
# "tikjot-notary", and the Sparkle EdDSA private key (Keychain account "tikjot", made by Sparkle's generate_keys).
# Bumps MARKETING_VERSION and (once per new version) CURRENT_PROJECT_VERSION in project.yml — commit that afterwards.
# Safe to re-run: the same version keeps its build number; everything for it is rebuilt from scratch.
# Release notes (required): release-notes/<version>.md (English) and release-notes/<version>.sk.md (Slovak), committed
# in the repo. They go into the appcast item as <description xml:lang="en|sk"> (HTML, scripts/release-notes.py) and
# into dist/<version>/release-notes.md for the GitHub release body.
set -o pipefail
cd "$(dirname "$0")/.."
VERSION=$1
TEAM=UPB9VSQ76D
NOTARY_PROFILE=tikjot-notary
SPARKLE_ACCOUNT=tikjot
die() { echo "error: $*" >&2; exit 1; }
step() { echo "==> $*"; }

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "usage: scripts/release.sh <major.minor.patch>"
# Release notes first — nothing is built until both languages are written (and no section is left empty).
python3 scripts/release-notes.py check "$VERSION" || exit 1
IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application: .*($TEAM)" | head -1 | awk '{print $2}')
[ -n "$IDENTITY" ] || die "no \"Developer ID Application (…$TEAM)\" certificate in the keychain"
[ -n "$(git status --porcelain -- . ':!project.yml')" ] && echo "warning: uncommitted changes — they go into this build"

# create-dmg (Homebrew) lays out the DMG window through Finder itself — background, 128 px icons, positions, volume
# icon. dmgbuild wrote the .DS_Store directly, but Finder on macOS 26 ignored its background (2026-10-07).
# The first run asks once that Terminal may control Finder (Automation) and briefly opens the DMG window.
command -v create-dmg >/dev/null || die "create-dmg missing — brew install create-dmg"
[ -f scripts/dmg/background.png ] || die "scripts/dmg/background.png missing (scripts/dmg/render-background.sh)"

# 1. Version: marketing version = <version>; the build number (what Sparkle compares) goes up once per new version.
CUR_VERSION=$(sed -n 's/^    MARKETING_VERSION: "\(.*\)"$/\1/p' project.yml)
CUR_BUILD=$(sed -n 's/^    CURRENT_PROJECT_VERSION: "\(.*\)"$/\1/p' project.yml)
[ -n "$CUR_VERSION" ] && [[ "$CUR_BUILD" =~ ^[0-9]+$ ]] || die "MARKETING_VERSION / CURRENT_PROJECT_VERSION not found in project.yml"
if [ "$CUR_VERSION" != "$VERSION" ]; then
  BUILD=$((CUR_BUILD + 1))
  sed -i '' -e "s/^    MARKETING_VERSION: \".*\"$/    MARKETING_VERSION: \"$VERSION\"/" \
            -e "s/^    CURRENT_PROJECT_VERSION: \".*\"$/    CURRENT_PROJECT_VERSION: \"$BUILD\"/" project.yml
  step "version $CUR_VERSION ($CUR_BUILD) → $VERSION ($BUILD)"
else
  BUILD=$CUR_BUILD
  step "version $VERSION ($BUILD) — already set, rebuilding"
fi

DIST=dist/$VERSION
WORK=.build/release/$VERSION
DMG=$DIST/tikjot-$VERSION.dmg
rm -rf "$WORK" && mkdir -p "$WORK" "$DIST" || exit 1
# (also any old-style dist/<ver>/tikjot-<ver>.md/.html/.txt notes — generate_appcast would pick them up)
rm -f "$DMG" "$DIST/appcast.xml" "$DIST"/notary-*.json "$DIST/release-notes.md" "$DIST/tikjot-$VERSION".{md,html,txt}

# 2. Archive (Release: Developer ID, hardened runtime, timestamp, no get-task-allow) and export for Developer ID.
#    The export re-signs everything nested (the widget, Sparkle's Autoupdate / Updater.app / XPC services) with our
#    certificate — Sparkle's installer service only accepts a client from its own team.
step "archive"
xcodegen generate --quiet >/dev/null || exit 1
xcodebuild -project tikjot.xcodeproj -scheme tikjot -configuration Release -derivedDataPath .build/xcode-release \
  -archivePath "$WORK/tikjot.xcarchive" archive 2>&1 | grep -E "error:|ARCHIVE" || exit 1
[ -d "$WORK/tikjot.xcarchive" ] || die "archive failed"
cat > "$WORK/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>developer-id</string>
	<key>signingStyle</key><string>manual</string>
	<key>signingCertificate</key><string>Developer ID Application</string>
	<key>teamID</key><string>$TEAM</string>
	<key>destination</key><string>export</string>
</dict>
</plist>
PLIST
step "export (Developer ID)"
xcodebuild -exportArchive -archivePath "$WORK/tikjot.xcarchive" -exportPath "$WORK/export" \
  -exportOptionsPlist "$WORK/ExportOptions.plist" 2>&1 | grep -E "error:|EXPORT" || exit 1
APP=$WORK/export/tikjot.app
[ -d "$APP" ] || die "export failed"

# 3. Verify the app: version, signature of every piece, entitlements, Sparkle settings.
step "verify signature + entitlements"
PLIST_APP=$APP/Contents/Info.plist
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST_APP")" = "$VERSION" ] || die "app version is not $VERSION"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST_APP")" = "$BUILD" ] || die "app build is not $BUILD"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2
codesign --verify --deep --strict "$APP" || die "codesign verification failed"
SPK=$APP/Contents/Frameworks/Sparkle.framework/Versions/B
for B in "$APP" "$APP/Contents/PlugIns/tikjotWidget.appex" "$APP/Contents/Frameworks/Sparkle.framework" \
         "$SPK/Autoupdate" "$SPK/Updater.app" "$SPK/XPCServices/Installer.xpc" "$SPK/XPCServices/Downloader.xpc"; do
  [ -e "$B" ] || die "missing $B"
  INFO=$(codesign -dvv "$B" 2>&1)
  echo "$INFO" | grep -q "^Authority=Developer ID Application: .*($TEAM)" || die "$B is not signed with our Developer ID"
  echo "$INFO" | grep -q "^TeamIdentifier=$TEAM" || die "$B has the wrong team"
  echo "$INFO" | grep -q "^Timestamp=" || die "$B has no secure timestamp"
  echo "$INFO" | grep -q "flags=.*runtime" || die "$B has no hardened runtime"
done
for B in "$APP" "$APP/Contents/PlugIns/tikjotWidget.appex"; do
  ENT=$(codesign -d --entitlements - --xml "$B" 2>/dev/null)
  echo "$ENT" | grep -q "com.apple.security.get-task-allow" && die "$B is signed with get-task-allow"
  echo "$ENT" | grep -q "<string>$TEAM.com.tikjot.mac</string>" || die "$B lacks the App Group $TEAM.com.tikjot.mac"
done
[ -n "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST_APP" 2>/dev/null)" ] || die "SUPublicEDKey is empty"
FEED=$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$PLIST_APP")
REPO=${FEED%/releases/latest/download/appcast.xml}
[ "$REPO" != "$FEED" ] || die "SUFeedURL is not a GitHub releases/latest/download/appcast.xml URL: $FEED"

# Submit to Apple's notary service, wait, keep the log; fails unless Accepted. Usage: notarize <file> <name>
# Upload first, then wait on the submission id: a dropped connection (sleep, Wi-Fi) only retries the waiting,
# it never re-uploads. Gives up after NOTARY_HOURS (default 6) — the id is printed to check later.
notarize() {
  local out=$DIST/notary-$2.json id status="" deadline=$(( $(date +%s) + ${NOTARY_HOURS:-6} * 3600 ))
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --output-format json > "$out" || { cat "$out"; die "notarytool submit failed ($1)"; }
  id=$(plutil -extract id raw "$out") || die "no submission id from notarytool"
  echo "    $2: submitted ($id), waiting for Apple…"
  while [ "$(date +%s)" -lt "$deadline" ]; do
    xcrun notarytool wait "$id" --keychain-profile "$NOTARY_PROFILE" --timeout 30m >/dev/null 2>&1
    xcrun notarytool info "$id" --keychain-profile "$NOTARY_PROFILE" --output-format json > "$out" 2>/dev/null \
      && status=$(plutil -extract status raw "$out" 2>/dev/null) || status=""
    case $status in
      Accepted|Invalid|Rejected) break ;;
      *) sleep 30 ;;   # In Progress, or offline for a moment
    esac
  done
  xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" "$DIST/notary-$2-log.json" >/dev/null 2>&1
  echo "    $2: ${status:-no answer} (submission $id)"
  [ "$status" = Accepted ] || die "notarization of $1: ${status:-no answer} — xcrun notarytool info $id --keychain-profile $NOTARY_PROFILE; log in $DIST/notary-$2-log.json"
}

# 4. Notarize + staple the app itself, so it opens offline once copied out of the DMG.
step "notarize app"
ditto -c -k --keepParent "$APP" "$WORK/tikjot.zip" || exit 1
notarize "$WORK/tikjot.zip" app
xcrun stapler staple -q "$APP" && xcrun stapler validate -q "$APP" || die "stapling the app failed"
spctl -a -t exec -vv "$APP" 2>&1 | sed 's/^/    /'
spctl -a -t exec "$APP" 2>/dev/null || die "Gatekeeper rejects the app"

# 5. DMG: tikjot.app + /Applications link in a fixed 640×400 window with the branded background and the app icon as
#    the volume icon (create-dmg via Finder), UDZO compressed; then signed, notarized, stapled.
step "DMG"
STAGE=$(mktemp -d) && cp -R "$APP" "$STAGE/"
create-dmg --volname tikjot --volicon "$APP/Contents/Resources/AppIcon.icns" --background scripts/dmg/background.png \
  --window-pos 200 120 --window-size 640 400 --icon-size 128 --text-size 13 \
  --icon tikjot.app 160 190 --hide-extension tikjot.app --app-drop-link 480 190 --no-internet-enable \
  "$DMG" "$STAGE" >/dev/null || die "create-dmg failed"
rm -rf "$STAGE"
codesign --verify --deep --strict "$(hdiutil attach -nobrowse -readonly "$DMG" | awk -F'\t' '/Volumes/{print $NF}')/tikjot.app" \
  || die "the app inside the DMG fails codesign"; hdiutil detach "/Volumes/tikjot" -quiet
codesign --force --sign "$IDENTITY" --timestamp "$DMG" && codesign --verify --strict "$DMG" || die "signing the DMG failed"
step "notarize DMG"
notarize "$DMG" dmg
xcrun stapler staple -q "$DMG" && xcrun stapler validate -q "$DMG" || die "stapling the DMG failed"
spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1 | sed 's/^/    /'
spctl -a -t open --context context:primary-signature "$DMG" 2>/dev/null || die "Gatekeeper rejects the DMG"

# 6. Sparkle: EdDSA-sign the (final, stapled) DMG into appcast.xml, on top of the previous release's appcast so the
#    feed keeps its history. The private key comes from the Keychain via generate_keys (the tool that created it, so
#    no Keychain prompt) into a private temp file that is removed right after.
step "Sparkle appcast"
SPARKLE_BIN=$(ls -d .build/xcode-release/SourcePackages/artifacts/sparkle/Sparkle/bin 2>/dev/null)
[ -x "$SPARKLE_BIN/generate_appcast" ] || die "Sparkle tools not found (expected in .build/xcode-release/SourcePackages/artifacts)"
PREV=$(ls dist/*/appcast.xml 2>/dev/null | grep -v "^$DIST/" | sort -t/ -k2 -V | tail -1)
[ -n "$PREV" ] && cp "$PREV" "$DIST/appcast.xml" && echo "    on top of $PREV"
KEYDIR=$(mktemp -d) && chmod 700 "$KEYDIR" || exit 1
trap 'rm -P "$KEYDIR/key" 2>/dev/null; rm -rf "$KEYDIR"' EXIT
"$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -x "$KEYDIR/key" >/dev/null || die "can't read the Sparkle key (account $SPARKLE_ACCOUNT)"
"$SPARKLE_BIN/generate_appcast" --ed-key-file "$KEYDIR/key" --download-url-prefix "$REPO/releases/download/v$VERSION/" \
  --maximum-versions 0 --maximum-deltas 0 "$DIST" || die "generate_appcast failed"
rm -P "$KEYDIR/key"
rm -rf "$DIST/old_updates"
grep -q "sparkle:edSignature" "$DIST/appcast.xml" && grep -q "v$VERSION/tikjot-$VERSION.dmg" "$DIST/appcast.xml" \
  || die "appcast.xml has no signed item for $VERSION"

# 7. Release notes: every item with release-notes/<ver>.md + .sk.md gets <description xml:lang="en"> and
#    <description xml:lang="sk"> (small HTML; Sparkle shows the one matching the user's language, English otherwise).
#    Only the description elements change — the enclosure and its edSignature (which signs the DMG) stay as written.
#    English Markdown for the GitHub release body goes to dist/<ver>/release-notes.md.
step "release notes"
python3 scripts/release-notes.py appcast "$DIST/appcast.xml" || die "adding release notes to appcast.xml failed"
grep -q "<description xml:lang=\"sk\">" "$DIST/appcast.xml" || die "appcast.xml has no Slovak release notes"
python3 scripts/release-notes.py github "$VERSION" "$DIST/release-notes.md" || die "writing $DIST/release-notes.md failed"

step "done"
ls -lh "$DMG" "$DIST/appcast.xml" "$DIST/release-notes.md" | awk '{print "    " $5 "\t" $NF}'
cat <<EOF

Release notes ($DIST/release-notes.md):
$(sed 's/^/  | /' "$DIST/release-notes.md")

Next (manual — nothing was uploaded):
  1. Commit project.yml (version $VERSION, build $BUILD) and release-notes/$VERSION*.md.
  2. On GitHub ($REPO): create release "v$VERSION" (tag v$VERSION) with the notes above and attach the DMG and
     appcast.xml, e.g.
       gh release create v$VERSION $DMG $DIST/appcast.xml --repo ${REPO#https://github.com/} \\
         --title "tikjot $VERSION" --notes-file $DIST/release-notes.md
     The feed is $FEED — the latest release must carry appcast.xml.
EOF
