#!/bin/bash
set -e

cd "$(dirname "$0")/.."
PROJECT_DIR="$(pwd)"

echo "Building Spacey..."
swift build -c release 2>&1

BINARY="$PROJECT_DIR/.build/release/Spacey"
APP_DIR="$PROJECT_DIR/Spacey.app"

if [ ! -f "$BINARY" ]; then
    echo "Error: Build failed - binary not found at $BINARY"
    exit 1
fi

echo "Creating Spacey.app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"

cp "$BINARY" "$APP_DIR/Contents/MacOS/Spacey"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

echo "Build complete: $APP_DIR"
echo ""
echo "To run:  open $APP_DIR"
echo "To install: ./Scripts/install.sh"
