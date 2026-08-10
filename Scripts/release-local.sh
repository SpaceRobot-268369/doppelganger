#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: Scripts/release-local.sh <version>" >&2
  exit 64
fi

VERSION="$1"
SIGNING_IDENTITY="${DEVELOPER_ID_APPLICATION:-}"
NOTARY_PROFILE="${NOTARYTOOL_PROFILE:-}"

if [[ -z "$SIGNING_IDENTITY" || -z "$NOTARY_PROFILE" ]]; then
  echo "DEVELOPER_ID_APPLICATION and NOTARYTOOL_PROFILE are required" >&2
  exit 78
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/build/release/$VERSION"
ARCHIVE_PATH="$OUTPUT_DIR/Doppelganger.xcarchive"
APP_PATH="$ARCHIVE_PATH/Products/Applications/Doppelganger.app"
DMG_ROOT="$OUTPUT_DIR/dmg-root"
DMG_PATH="$OUTPUT_DIR/Doppelganger-$VERSION.dmg"

if [[ -e "$OUTPUT_DIR" ]]; then
  echo "release output already exists: $OUTPUT_DIR" >&2
  exit 73
fi

mkdir -p "$OUTPUT_DIR" "$DMG_ROOT"

xcodebuild test \
  -project "$ROOT_DIR/Doppelganger.xcodeproj" \
  -scheme Doppelganger \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO

xcodebuild archive \
  -project "$ROOT_DIR/Doppelganger.xcodeproj" \
  -scheme Doppelganger \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  MARKETING_VERSION="$VERSION" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
  OTHER_CODE_SIGN_FLAGS='--timestamp --options runtime'

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
cp -R "$APP_PATH" "$DMG_ROOT/"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create \
  -volname Doppelganger \
  -srcfolder "$DMG_ROOT" \
  -format UDZO \
  -ov \
  "$DMG_PATH"

xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"

shasum -a 256 "$DMG_PATH" > "$DMG_PATH.sha256"
echo "release ready: $DMG_PATH"
