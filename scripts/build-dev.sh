#!/bin/zsh
# Fork-only: build this checkout as "macshot Dev" with its own bundle ID so it
# can run beside an installed macshot (macshot quits itself when another copy
# with the same ID is running). The huge build number and disabled automatic
# checks keep Sparkle from "updating" it to the official release.
# Usage: scripts/build-dev.sh [--open]
set -euo pipefail
REPO=${0:A:h:h}
BUNDLE_ID=${MACSHOT_DEV_BUNDLE_ID:-com.dixon.macshot.dev}
OUT="/Applications/macshot Dev.app"

cd "$REPO"
xcodebuild -scheme macshot -configuration Debug -derivedDataPath "$REPO/build" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" CURRENT_PROJECT_VERSION=999999 \
  CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"

pkill -f "$OUT/Contents/MacOS/" 2>/dev/null || true
rm -rf "$OUT"
cp -R "$REPO/build/Build/Products/Debug/macshot.app" "$OUT"
plist="$OUT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName macshot Dev" "$plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string macshot Dev" "$plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName macshot Dev" "$plist"
/usr/libexec/PlistBuddy -c "Add :SUEnableAutomaticChecks bool false" "$plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :SUEnableAutomaticChecks false" "$plist"
codesign --force --deep --sign - "$OUT" >/dev/null 2>&1
echo "Built: $OUT ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist"))"
[[ "${1:-}" == "--open" ]] && open "$OUT"
exit 0
