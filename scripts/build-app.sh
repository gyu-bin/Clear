#!/bin/zsh
# Builds a Release Clear.app into dist/, zips it, and makes a drag-to-install DMG.
#
# Signing: if an "Apple Development" certificate is in the keychain, the app is
# signed with it. macOS privacy permissions (Full Disk Access, folder access)
# are remembered per signing identity, so a stable certificate means a
# permission granted once survives every rebuild. Without a certificate the app
# is ad-hoc signed and macOS may ask again after each build.
#
# Usage: scripts/build-app.sh [--install]   (--install also copies it to /Applications)
set -euo pipefail
cd "$(dirname "$0")/.."

sign_args=()
identity=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 '"Apple Development' | sed -E 's/.*"(.*)"/\1/' || true)
if [[ -n "$identity" ]]; then
  team=$(security find-certificate -c "$identity" -p | openssl x509 -noout -subject 2>/dev/null | tr ',' '\n' | sed -n 's/^ *OU=//p' | head -1)
  sign_args=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$identity" "DEVELOPMENT_TEAM=$team")
  echo "signing with: $identity ($team)"
else
  echo "no Apple Development certificate found — ad-hoc signing"
fi

xcodebuild -project Clear.xcodeproj -scheme Clear -configuration Release \
  -derivedDataPath build/DerivedData "${sign_args[@]}" build | grep -E "error:|BUILD" || true
app="build/DerivedData/Build/Products/Release/Clear.app"
[[ -d "$app" ]] || { echo "build failed"; exit 1; }
rm -rf dist && mkdir -p dist
ditto "$app" dist/Clear.app
ditto -c -k --keepParent dist/Clear.app dist/Clear.zip
codesign --verify --deep --strict dist/Clear.app && echo "signature ok"

# DMG: the app plus an Applications shortcut, so it installs by dragging.
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" dist/Clear.app/Contents/Info.plist)
staging=build/dmg
rm -rf "$staging" && mkdir -p "$staging"
ditto dist/Clear.app "$staging/Clear.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "Clear $version" -srcfolder "$staging" -fs HFS+ \
  -format UDZO -ov "dist/Clear-$version.dmg" >/dev/null
[[ -n "$identity" ]] && codesign --sign "$identity" "dist/Clear-$version.dmg"
echo "dist/Clear-$version.dmg"
if [[ "${1:-}" == "--install" ]]; then
  rm -rf /Applications/Clear.app
  ditto dist/Clear.app /Applications/Clear.app
  echo "installed to /Applications/Clear.app"
fi
echo "dist/Clear.app, dist/Clear.zip"
