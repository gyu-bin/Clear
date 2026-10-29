#!/bin/zsh
# Builds a Release Clear.app into dist/, zips it, and makes a drag-to-install DMG.
#
# Signing, best first:
#   1. "Developer ID Application" certificate: the DMG is notarized by Apple and
#      opens on any Mac without a Gatekeeper warning. Notarization needs the
#      credentials saved once with:
#        xcrun notarytool store-credentials clear-notary \
#          --apple-id <Apple ID> --team-id <team ID>
#      (it asks for an app-specific password from appleid.apple.com).
#   2. "Apple Development" certificate: fine on this Mac, but a downloaded copy
#      is blocked by Gatekeeper.
#   3. Neither: ad-hoc signing.
# macOS privacy permissions (Full Disk Access, folder access) are remembered per
# signing identity, so a stable certificate means a permission granted once
# survives every rebuild; switching identity means granting it once more.
#
# Usage: scripts/build-app.sh [--install]   (--install also copies it to /Applications)
# NOTARY_PROFILE overrides the notarytool keychain profile name (default clear-notary).
set -euo pipefail
cd "$(dirname "$0")/.."

find_identity() {
  security find-identity -v -p codesigning 2>/dev/null | grep -m1 "\"$1" | sed -E 's/.*"(.*)"/\1/' || true
}

sign_args=()
developer_id=false
identity=$(find_identity "Developer ID Application")
if [[ -n "$identity" ]]; then
  developer_id=true
else
  identity=$(find_identity "Apple Development")
fi
if [[ -n "$identity" ]]; then
  team=$(security find-certificate -c "$identity" -p | openssl x509 -noout -subject 2>/dev/null | tr ',' '\n' | sed -n 's/^ *OU=//p' | head -1)
  sign_args=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$identity" "DEVELOPMENT_TEAM=$team")
  # Notarization needs a secure timestamp and no debugging entitlement.
  $developer_id && sign_args+=(OTHER_CODE_SIGN_FLAGS=--timestamp CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO)
  echo "signing with: $identity ($team)"
else
  echo "no signing certificate found — ad-hoc signing"
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
  -format UDZO -ov dist/Clear.dmg >/dev/null
if $developer_id; then
  codesign --sign "$identity" --timestamp dist/Clear.dmg
elif [[ -n "$identity" ]]; then
  codesign --sign "$identity" dist/Clear.dmg
fi

# Notarize so downloaded copies open without a Gatekeeper warning.
notary_profile=${NOTARY_PROFILE:-clear-notary}
if $developer_id; then
  if xcrun notarytool history --keychain-profile "$notary_profile" >/dev/null 2>&1; then
    echo "notarizing (usually a few minutes)…"
    xcrun notarytool submit dist/Clear.dmg --keychain-profile "$notary_profile" --wait | tee build/notary.log
    grep -q "status: Accepted" build/notary.log || { echo "notarization failed — see: xcrun notarytool log <id> --keychain-profile $notary_profile"; exit 1; }
    xcrun stapler staple dist/Clear.dmg
    spctl -a -t open --context context:primary-signature -v dist/Clear.dmg
  else
    echo "WARNING: no notarytool profile '$notary_profile' — DMG is signed but not notarized (see top of this script)"
  fi
fi
echo "dist/Clear.dmg"
if [[ "${1:-}" == "--install" ]]; then
  rm -rf /Applications/Clear.app
  ditto dist/Clear.app /Applications/Clear.app
  echo "installed to /Applications/Clear.app"
fi
echo "dist/Clear.app, dist/Clear.zip"
