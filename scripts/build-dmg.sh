#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-${DOMA_VERSION:-0.1.0}}"
BUILD_NUMBER="${DOMA_BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-1}}"
DIST_DIR="$ROOT/dist"
DMG_PATH="$DIST_DIR/Doma-$VERSION.dmg"
TEMP_DMG_PATH="$DIST_DIR/Doma-$VERSION-rw.dmg"
STAGE_DIR="$DIST_DIR/dmg-root"
BACKGROUND_SOURCE="$ROOT/Resources/dmg-background.png"
VOLUME_NAME="Doma"
BUILD_VOLUME_NAME="$VOLUME_NAME-build-$$"

detach_temp_dmg() {
  /usr/bin/hdiutil info | /usr/bin/awk -v image_path="$TEMP_DMG_PATH" '
    /^image-path/ { active = (index($0, image_path) > 0) }
    active && /^\/dev\/disk[0-9]+s[0-9]+/ { print $1 }
  ' | while read -r device; do
    /usr/bin/hdiutil detach "$device" >/dev/null 2>&1 || true
  done
}

detach_temp_dmg
rm -rf "$DIST_DIR"
mkdir -p "$STAGE_DIR/.background"

APP_DIR="$(DOMA_VERSION="$VERSION" DOMA_BUILD_NUMBER="$BUILD_NUMBER" "$ROOT/scripts/build-app.sh" | tail -n 1)"
STAGED_APP_DIR="$STAGE_DIR/Doma.app"

/usr/bin/ditto "$APP_DIR" "$STAGED_APP_DIR"
/usr/bin/codesign --force --deep --sign - "$STAGED_APP_DIR"
/bin/cp "$BACKGROUND_SOURCE" "$STAGE_DIR/.background/dmg-background.png"

/usr/bin/hdiutil create \
  -volname "$BUILD_VOLUME_NAME" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -fs HFS+ \
  -format UDRW \
  "$TEMP_DMG_PATH"

MOUNT_DIR=""
cleanup() {
  detach_temp_dmg
  /bin/rm -rf "$STAGE_DIR" "$TEMP_DMG_PATH"
}
trap cleanup EXIT

ATTACH_OUTPUT="$(/usr/bin/hdiutil attach "$TEMP_DMG_PATH" \
  -readwrite \
  -noverify \
  -noautoopen)"
MOUNT_DIR="$(/usr/bin/printf '%s\n' "$ATTACH_OUTPUT" | /usr/bin/awk -F'\t' '$0 ~ /\/Volumes\// {print $NF; exit}')"
/usr/bin/chflags hidden "$MOUNT_DIR/.background"
BACKGROUND_ALIAS="$MOUNT_DIR/.background/dmg-background.png"

/usr/bin/osascript <<OSA
set dmgFolder to POSIX file "$MOUNT_DIR" as alias
set backgroundImage to POSIX file "$BACKGROUND_ALIAS" as alias

tell application "Finder"
    tell disk "$BUILD_VOLUME_NAME"
        open
        set dmgWindow to container window

        if not (exists item "Applications" of dmgWindow) then
            make new alias file to (POSIX file "/Applications" as alias) at dmgWindow with properties {name:"Applications"}
        end if

        set current view of dmgWindow to icon view
        set toolbar visible of dmgWindow to false
        set statusbar visible of dmgWindow to false
        set bounds of dmgWindow to {100, 100, 740, 500}

        set viewOptions to icon view options of dmgWindow
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set background picture of viewOptions to backgroundImage

        set position of item "Doma.app" of dmgWindow to {180, 220}
        set position of item "Applications" of dmgWindow to {460, 220}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
OSA

/bin/sync
/bin/rm -rf "$MOUNT_DIR/.fseventsd" "$MOUNT_DIR/.Trashes"
/usr/sbin/diskutil rename "$MOUNT_DIR" "$VOLUME_NAME" >/dev/null
detach_temp_dmg
MOUNT_DIR=""

/usr/bin/hdiutil convert "$TEMP_DMG_PATH" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$DMG_PATH"

/usr/bin/hdiutil verify "$DMG_PATH"
echo "$DMG_PATH"
