#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
MACPULSE_ROOT="$(cd .. && pwd)"
MACPULSE_BUILD="${MACPULSE_BUILD_DIR:-$MACPULSE_ROOT/.build}"
MACPULSE_FIXTURE="$MACPULSE_BUILD/TestFixture.app"
mkdir -p "$MACPULSE_FIXTURE/Contents/MacOS"
cp "$MACPULSE_ROOT/轻诊.app/Contents/MacOS/MacPulse" "$MACPULSE_FIXTURE/Contents/MacOS/Fixture"
cat > "$MACPULSE_FIXTURE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.hb.macpulse.fixture</string>
<key>CFBundleExecutable</key><string>Fixture</string>
<key>CFBundleName</key><string>MacPulseTestFixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
xattr -cr "$MACPULSE_FIXTURE"
if xattr -p com.apple.FinderInfo "$MACPULSE_FIXTURE" >/dev/null 2>&1; then xattr -d com.apple.FinderInfo "$MACPULSE_FIXTURE"; fi
codesign --force --sign - "$MACPULSE_FIXTURE"
"$MACPULSE_ROOT/轻诊.app/Contents/MacOS/MacPulse" --selftest "--fixture=$MACPULSE_FIXTURE/Contents/MacOS/Fixture"
