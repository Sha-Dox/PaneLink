#!/bin/sh
# Builds both apps and zips them for a GitHub release: dist/PaneLink-mac.zip, dist/PaneLink-windows.zip.
#   VERSION=1.2.0 scripts/package.sh
set -e
cd "$(dirname "$0")/.."
VERSION=${VERSION:-dev}
rm -rf dist && mkdir -p dist
NO_INSTALL=1 VERSION="$VERSION" mac/bundle.sh
ditto -c -k --norsrc --noextattr --keepParent mac/build/PaneLink.app dist/PaneLink-mac.zip
windows/build.sh
mkdir -p dist/PaneLink-windows
cp windows/dist/* dist/PaneLink-windows/
cp windows/deps/ffmpeg/LICENSE.txt dist/PaneLink-windows/FFMPEG-LICENSE.txt
cp LICENSE dist/PaneLink-windows/
(cd dist && zip -qr PaneLink-windows.zip PaneLink-windows && rm -rf PaneLink-windows)
ls -la dist
