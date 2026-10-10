#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
AERIAL_SWIFTC="${AERIAL_SWIFTC:-/usr/bin/swiftc}"
AERIAL_SDK="${AERIAL_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
OUTPUT_DIR="${AERIAL_OUTPUT_DIR:-$PROJECT_DIR/build}"
APP_PATH="$OUTPUT_DIR/AerialController.app"

if [[ ! -d "$AERIAL_SDK" ]]; then
    printf 'Missing compatible macOS SDK: %s\nSet AERIAL_SDK to your compiler-compatible SDK.\n' "$AERIAL_SDK" >&2
    exit 1
fi

mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" "$OUTPUT_DIR/module-cache"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
if [[ -n "${AERIAL_DEVELOPMENT_SUPPORT_DIRECTORY:-}" ]]; then
    /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier org.openaerial.controller.dev' "$APP_PATH/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :AerialDevelopmentSupportDirectory string $AERIAL_DEVELOPMENT_SUPPORT_DIRECTORY" "$APP_PATH/Contents/Info.plist"
fi

"$AERIAL_SWIFTC" -swift-version 6 -parse-as-library -O \
    -sdk "$AERIAL_SDK" -target arm64-apple-macosx26.0 \
    -module-cache-path "$OUTPUT_DIR/module-cache" \
    "$PROJECT_DIR"/Sources/AerialCore/*.swift \
    "$PROJECT_DIR"/Sources/AerialController/*.swift \
    -o "$APP_PATH/Contents/MacOS/AerialController"

/usr/bin/codesign --force --sign - "$APP_PATH"
/usr/bin/codesign --verify --strict "$APP_PATH"
/usr/bin/plutil -lint "$APP_PATH/Contents/Info.plist"
printf '%s\n' "$APP_PATH"
