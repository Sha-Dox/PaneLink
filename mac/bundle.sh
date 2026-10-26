#!/bin/sh
# Builds PaneLink.app and installs it to /Applications.
#   SIGN_ID   codesign identity (default: your first "Apple Development" certificate, else ad-hoc "-").
#             A real identity keeps Screen Recording / Accessibility permissions across rebuilds.
#   NO_INSTALL=1  only build mac/build/PaneLink.app      NO_RESTART=1  install but leave the running copy alone
#   VERSION   CFBundleShortVersionString (default 1.0)
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/PaneLink.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/PaneLink "$APP/Contents/MacOS/PaneLink"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID:-com.mertsuntur.panelink}</string>
  <key>CFBundleName</key><string>PaneLink</string>
  <key>CFBundleDisplayName</key><string>PaneLink</string>
  <key>CFBundleExecutable</key><string>PaneLink</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION:-1.0}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>PaneLink streams your extra displays to your Windows PC on the local network.</string>
  <key>NSAppleEventsUsageDescription</key><string>Used to toggle AWDL for lower Wi-Fi latency.</string>
</dict></plist>
PLIST
# icons: regenerate with ../tools/make_icons.py
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/" && /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
cp Resources/MenuIcon*.png "$APP/Contents/Resources/" 2>/dev/null || true
if [ -z "$SIGN_ID" ]; then
  SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)
  SIGN_ID=${SIGN_ID:--}
fi
codesign --force --options runtime --sign "$SIGN_ID" "$APP"
echo "Signed with: $SIGN_ID"
[ -n "$NO_INSTALL" ] && { echo "Built $APP"; exit 0; }
# NO_RESTART=1: swap the app on disk but leave the running copy alone (it keeps its old binary until relaunched)
if [ -z "$NO_RESTART" ]; then
  pkill -x PaneLink || true
  while pgrep -x PaneLink >/dev/null; do sleep 0.2; done
fi
rm -rf /Applications/PaneLink.app
cp -R "$APP" /Applications/
echo "Installed /Applications/PaneLink.app"
