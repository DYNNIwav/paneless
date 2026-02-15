#!/bin/bash
set -e

cd "$(dirname "$0")/.."
PROJECT_DIR="$(pwd)"

echo "Building Paneless..."
swift build -c release 2>&1

BINARY="$PROJECT_DIR/.build/release/Paneless"
APP_DIR="$PROJECT_DIR/Paneless.app"

if [ ! -f "$BINARY" ]; then
    echo "Error: Build failed - binary not found at $BINARY"
    exit 1
fi

echo "Creating Paneless.app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BINARY" "$APP_DIR/Contents/MacOS/Paneless"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

# Copy app icon if it exists
if [ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]; then
    cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

echo "Build complete: $APP_DIR"
echo ""
echo "To run:  open $APP_DIR"
echo "To install: ./Scripts/install.sh"
