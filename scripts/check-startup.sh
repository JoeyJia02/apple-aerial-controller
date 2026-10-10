#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
AERIAL_SWIFTC="${AERIAL_SWIFTC:-/usr/bin/swiftc}"
AERIAL_SDK="${AERIAL_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
CHECK_DIR="$PROJECT_DIR/build/startup-checks"
mkdir -p "$CHECK_DIR/module-cache"
"$AERIAL_SWIFTC" -swift-version 6 -parse-as-library -sdk "$AERIAL_SDK" -target arm64-apple-macosx26.0 \
    -module-cache-path "$CHECK_DIR/module-cache" \
    "$PROJECT_DIR/Sources/AerialCore/AerialCatalog.swift" \
    "$PROJECT_DIR/Sources/AerialCore/RotationScheduler.swift" \
    "$PROJECT_DIR/Sources/AerialCore/NativeAerialSwitcher.swift" \
    "$PROJECT_DIR/Sources/AerialController/Preferences.swift" \
    "$PROJECT_DIR/Sources/AerialController/DesktopReplayController.swift" \
    "$PROJECT_DIR/Sources/AerialController/AppModel.swift" \
    "$PROJECT_DIR/Tests/AppModelStartupChecks.swift" -o "$CHECK_DIR/startup-checks"
AERIAL_FIXTURE_DIRECTORY="$CHECK_DIR/session-$(/usr/bin/uuidgen)"
printf 'Startup-only checks; synthetic owned fixtures; no wallpaper selection methods.\nSession: %s\n' "$AERIAL_FIXTURE_DIRECTORY"
"$CHECK_DIR/startup-checks" "$AERIAL_FIXTURE_DIRECTORY"
