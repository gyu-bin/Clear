#!/bin/zsh
# Builds a Release Clear.app into dist/ (ad-hoc signed, for this Mac) and zips it.
# Usage: scripts/build-app.sh [--install]   (--install also copies it to /Applications)
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project Clear.xcodeproj -scheme Clear -configuration Release \
  -derivedDataPath build/DerivedData build | grep -E "error:|BUILD" || true
app="build/DerivedData/Build/Products/Release/Clear.app"
[[ -d "$app" ]] || { echo "build failed"; exit 1; }
rm -rf dist && mkdir -p dist
ditto "$app" dist/Clear.app
ditto -c -k --keepParent dist/Clear.app dist/Clear.zip
codesign --verify --deep --strict dist/Clear.app && echo "signature ok"
if [[ "${1:-}" == "--install" ]]; then
  ditto dist/Clear.app /Applications/Clear.app
  echo "installed to /Applications/Clear.app"
fi
echo "dist/Clear.app, dist/Clear.zip"
