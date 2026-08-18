#!/bin/bash
# Build and install a development build into /Applications/Paneless.app.
#
# Signs with the stable Apple Development identity rather than ad-hoc. Ad-hoc
# signing gives the binary a new code directory hash on every build, so macOS
# treats each deploy as a different app and revokes the Accessibility grant,
# forcing you to approve Paneless again after every single build. A stable
# signing identity keeps the grant.
set -euo pipefail

cd "$(dirname "$0")/.."

APP="/Applications/Paneless.app"
IDENTITY="${PANELESS_SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
    | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"

if [ -z "$IDENTITY" ]; then
    echo "No signing identity found, falling back to ad-hoc."
    echo "You will have to re-approve Accessibility after each deploy."
    IDENTITY="-"
fi

echo "Building..."
swift build

echo "Installing to $APP"
cp .build/debug/Paneless "$APP/Contents/MacOS/Paneless"

echo "Signing as: $IDENTITY"
codesign --force --deep --sign "$IDENTITY" "$APP"
codesign --verify --verbose "$APP" 2>&1 | tail -2

pkill -x Paneless 2>/dev/null || true
sleep 1
open "$APP"
sleep 2

if pgrep -x Paneless >/dev/null; then
    echo "Paneless running (pid $(pgrep -x Paneless))"
else
    echo "Paneless failed to start" >&2
    exit 1
fi
