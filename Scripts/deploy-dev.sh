#!/bin/bash
# Build and install a development build into /Applications/Paneless.app.
#
# Signs with the same Developer ID certificate a release uses. macOS keys the
# Accessibility grant on the app's designated requirement, and that requirement names
# the signing certificate, so a dev build signed with a different one counts as a
# different app and has to be approved all over again. Signing both the same way means
# the grant is given once and then left alone, whichever build happens to be installed.
set -euo pipefail

cd "$(dirname "$0")/.."

APP="/Applications/Paneless.app"
source Scripts/signing-identity.sh
IDENTITY="${PANELESS_SIGN_IDENTITY:-$(paneless_developer_id_hash)}"

if [ -z "$IDENTITY" ]; then
    IDENTITY="$(paneless_apple_development_hash)"
    echo "No Developer ID certificate found, falling back to Apple Development."
    echo "Moving between this build and a release will ask for Accessibility once."
fi

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
