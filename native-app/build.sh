#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
MACPULSE_ROOT="$(cd .. && pwd)"
MACPULSE_BUILD="${MACPULSE_BUILD_DIR:-$MACPULSE_ROOT/.build}"
MACPULSE_APP="${MACPULSE_APP_DIR:-$MACPULSE_ROOT/轻诊.app}"
mkdir -p "$MACPULSE_BUILD" "$MACPULSE_APP/Contents/MacOS" "$MACPULSE_APP/Contents/Resources"
xcrun clang -O2 -target arm64-apple-macos12.0 -c MonitorBridge.c -o "$MACPULSE_BUILD/MonitorBridge.o"
xcrun swiftc -O -swift-version 5 -module-cache-path "$MACPULSE_BUILD/ModuleCache" -target arm64-apple-macos12.0 -import-objc-header MonitorBridge.h \
  Monitor.swift DiskCleaner.swift DiskInterface.swift DiskTests.swift DuplicateFinder.swift NetworkHealth.swift CaptureTemporaryFiles.swift PacketCapture.swift PacketCaptureInterface.swift PacketCaptureTests.swift ToolInterfaces.swift ToolTests.swift AppUninstaller.swift UninstallInterface.swift UninstallTests.swift Interface.swift main.swift "$MACPULSE_BUILD/MonitorBridge.o" -o "$MACPULSE_APP/Contents/MacOS/MacPulse"
cp Info.plist "$MACPULSE_APP/Contents/Info.plist"
xcrun swiftc -module-cache-path "$MACPULSE_BUILD/ModuleCache" Icon.swift -o "$MACPULSE_BUILD/Icon"
"$MACPULSE_BUILD/Icon" "$MACPULSE_BUILD/icon.png"
MACPULSE_ICONSET="$MACPULSE_BUILD/AppIcon.iconset"
mkdir -p "$MACPULSE_ICONSET"
for MACPULSE_SIZE in 16 32 128 256 512; do
  sips -z "$MACPULSE_SIZE" "$MACPULSE_SIZE" "$MACPULSE_BUILD/icon.png" --out "$MACPULSE_ICONSET/icon_${MACPULSE_SIZE}x${MACPULSE_SIZE}.png" >/dev/null
  MACPULSE_DOUBLE=$((MACPULSE_SIZE * 2))
  sips -z "$MACPULSE_DOUBLE" "$MACPULSE_DOUBLE" "$MACPULSE_BUILD/icon.png" --out "$MACPULSE_ICONSET/icon_${MACPULSE_SIZE}x${MACPULSE_SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$MACPULSE_ICONSET" -o "$MACPULSE_APP/Contents/Resources/AppIcon.icns"
plutil -replace CFBundleIconFile -string AppIcon.icns "$MACPULSE_APP/Contents/Info.plist"
xattr -cr "$MACPULSE_APP"
if xattr -p com.apple.FinderInfo "$MACPULSE_APP" >/dev/null 2>&1; then xattr -d com.apple.FinderInfo "$MACPULSE_APP"; fi
codesign --force --sign - "$MACPULSE_APP"
echo "Built: $MACPULSE_APP"
