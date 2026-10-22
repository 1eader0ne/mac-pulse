#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
MACPULSE_ROOT="$(cd .. && pwd)"
MACPULSE_APP="${MACPULSE_APP_DIR:-$MACPULSE_ROOT/轻诊.app}"
MACPULSE_STAGE="$(mktemp -d /private/tmp/macpulse-package.XXXXXX)"
# This disposable directory is created by this script only.
trap 'rm -rf "$MACPULSE_STAGE"' EXIT
ditto --norsrc --noextattr --noqtn "$MACPULSE_APP" "$MACPULSE_STAGE/轻诊.app"
ln -s /Applications "$MACPULSE_STAGE/Applications"
codesign --verify --deep --strict "$MACPULSE_STAGE/轻诊.app"
hdiutil create -volname "轻诊 1.4.0" -srcfolder "$MACPULSE_STAGE" -ov -format UDZO "$MACPULSE_ROOT/轻诊-1.4.0.dmg"
hdiutil verify "$MACPULSE_ROOT/轻诊-1.4.0.dmg"
