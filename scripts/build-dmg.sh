#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-${DOMA_VERSION:-0.1.0}}"
BUILD_NUMBER="${DOMA_BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-1}}"
DIST_DIR="$ROOT/dist"
DMG_PATH="$DIST_DIR/Doma-$VERSION.dmg"
STAGE_DIR="$DIST_DIR/dmg-root"

rm -rf "$DIST_DIR"
mkdir -p "$STAGE_DIR"

APP_DIR="$(DOMA_VERSION="$VERSION" DOMA_BUILD_NUMBER="$BUILD_NUMBER" "$ROOT/scripts/build-app.sh" | tail -n 1)"
/usr/bin/ditto "$APP_DIR" "$STAGE_DIR/Doma.app"
/bin/ln -s /Applications "$STAGE_DIR/Applications"

/usr/bin/hdiutil create \
  -volname "Doma" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

/usr/bin/hdiutil verify "$DMG_PATH"
rm -rf "$STAGE_DIR"

echo "$DMG_PATH"
