#!/bin/bash
set -e

# Usage: ./Scripts/release.sh v1.1.0
# Builds, signs, notarizes, uploads release, and updates the Homebrew cask.

VERSION="${1:?Usage: ./Scripts/release.sh vX.Y.Z}"
TEAM_ID="2WDPP87T4V"
IDENTITY="Developer ID Application: Pål Omland Eilevstjønn ($TEAM_ID)"
TAP_REPO="/tmp/homebrew-paneless"

cd "$(dirname "$0")/.."

echo "==> Building..."
swift build -c release 2>&1
./Scripts/build.sh

echo "==> Signing with Developer ID..."
codesign --force --deep --options runtime --sign "$IDENTITY" Paneless.app
codesign --verify --verbose Paneless.app

echo "==> Zipping..."
rm -f /tmp/Paneless.app.zip
zip -r /tmp/Paneless.app.zip Paneless.app

echo "==> Notarizing (this takes ~1 min)..."
xcrun notarytool submit /tmp/Paneless.app.zip \
  --keychain-profile "paneless-notarize" --wait

echo "==> Stapling..."
xcrun stapler staple Paneless.app
rm -f /tmp/Paneless.app.zip
zip -r /tmp/Paneless.app.zip Paneless.app

SHA=$(shasum -a 256 /tmp/Paneless.app.zip | awk '{print $1}')
echo "==> SHA256: $SHA"

echo "==> Uploading release $VERSION..."
gh release delete "$VERSION" --yes 2>/dev/null || true
gh release create "$VERSION" /tmp/Paneless.app.zip \
  --title "Paneless $VERSION" \
  --generate-notes

echo "==> Updating Homebrew cask..."
rm -rf "$TAP_REPO"
gh repo clone DYNNIwav/homebrew-paneless "$TAP_REPO"
cd "$TAP_REPO"
sed -i '' "s/version \".*\"/version \"${VERSION#v}\"/" Casks/paneless.rb
sed -i '' "s/sha256 \".*\"/sha256 \"$SHA\"/" Casks/paneless.rb
git add Casks/paneless.rb
git commit -m "Update to $VERSION"
git push origin main

# Sync the local Homebrew tap so `brew reinstall` picks up the new version immediately
LOCAL_TAP="$(brew --repository 2>/dev/null)/Library/Taps/dynniwav/homebrew-paneless"
if [ -d "$LOCAL_TAP" ]; then
  echo "==> Syncing local Homebrew tap..."
  git -C "$LOCAL_TAP" pull --ff-only origin main
fi

echo ""
echo "==> Done! Released $VERSION"
echo "    brew upgrade --cask paneless"
