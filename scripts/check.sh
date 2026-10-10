#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
AERIAL_SWIFTC="${AERIAL_SWIFTC:-/usr/bin/swiftc}"
AERIAL_SDK="${AERIAL_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
CHECK_DIR="$PROJECT_DIR/build/checks"
mkdir -p "$CHECK_DIR/module-cache" "$CHECK_DIR/preferences"
FLAGS=(-swift-version 6 -parse-as-library -sdk "$AERIAL_SDK" -target arm64-apple-macosx26.0 -module-cache-path "$CHECK_DIR/module-cache")

"$AERIAL_SWIFTC" "${FLAGS[@]}" "$PROJECT_DIR/Sources/AerialCore/AerialCatalog.swift" "$PROJECT_DIR/Tests/CatalogChecks.swift" -o "$CHECK_DIR/catalog-checks"
"$CHECK_DIR/catalog-checks" --live
"$AERIAL_SWIFTC" "${FLAGS[@]}" "$PROJECT_DIR/Sources/AerialCore/RotationScheduler.swift" "$PROJECT_DIR/Tests/SchedulerChecks.swift" -o "$CHECK_DIR/scheduler-checks"
"$CHECK_DIR/scheduler-checks"
"$AERIAL_SWIFTC" "${FLAGS[@]}" "$PROJECT_DIR/Sources/AerialCore/NativeAerialSwitcher.swift" "$PROJECT_DIR/Tests/NativeSwitcherChecks.swift" -o "$CHECK_DIR/native-checks"
"$CHECK_DIR/native-checks"
"$AERIAL_SWIFTC" "${FLAGS[@]}" "$PROJECT_DIR/Sources/AerialController/Preferences.swift" "$PROJECT_DIR/Tests/PreferenceChecks.swift" -o "$CHECK_DIR/preference-checks"
"$CHECK_DIR/preference-checks" "$CHECK_DIR/preferences"
