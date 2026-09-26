#!/bin/bash
set -e
# Builds the Capacitor iOS wrapper for Scan & Log on this Mac.
# Run from inside the cloned scanlog repo: bash ios-build/setup.sh

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
PROJ_DIR="$HOME/projects/scanlogapk"

mkdir -p "$PROJ_DIR/www"
cp "$ROOT/app/index.html" "$PROJ_DIR/www/index.html"
cp "$ROOT/app/version.json" "$PROJ_DIR/www/version.json"
cp "$HERE/capacitor.config.json" "$PROJ_DIR/capacitor.config.json"
cp "$HERE/package.json" "$PROJ_DIR/package.json"

cd "$PROJ_DIR"
npm install
npx cap add ios

cp "$HERE/Info.plist" "$PROJ_DIR/ios/App/App/Info.plist"
cp "$HERE/GoogleService-Info.plist" "$PROJ_DIR/ios/App/App/GoogleService-Info.plist"

npx cap sync ios

echo "DONE: project ready at $PROJ_DIR"
echo "Next: open $PROJ_DIR/ios/App/App.xcworkspace in Xcode"
