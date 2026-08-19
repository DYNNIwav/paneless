#!/bin/bash
set -e

# Usage: ./Scripts/release.sh v1.1.0
# Builds, signs, notarizes, uploads release, and updates the Homebrew cask.

VERSION="${1:?Usage: ./Scripts/release.sh vX.Y.Z}"
TEAM_ID="2WDPP87T4V"
# Sign with the same certificate development builds use, so macOS sees one app and
# the Accessibility grant survives moving between a dev build and a release.
source "$(dirname "$0")/signing-identity.sh"
IDENTITY="$(paneless_developer_id_hash)"

if [ -z "$IDENTITY" ]; then
  echo "No usable Developer ID Application certificate in the keychain." >&2
  echo "Create one in Xcode: Settings > Accounts > Manage Certificates > + " >&2
  exit 1
fi
TAP_REPO="/tmp/homebrew-paneless"

cd "$(dirname "$0")/.."

# Stamp the version into the bundle before building.
#
# This used to be hardcoded in Resources/Info.plist and only the cask was updated,
# so every build shipped claiming 1.3.0 whatever it was tagged. Anything that reads
# the bundle version, About Paneless and the update check among them, was wrong.
NUM="${VERSION#v}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NUM" Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NUM" Resources/Info.plist
echo "==> Version stamped as $NUM"

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

# Commit the version stamp so the tag GitHub creates points at the source that
# was actually built. Without this the tag carries the old version number while
# the shipped binary reports the new one.
if ! git diff --quiet Resources/Info.plist; then
  git add Resources/Info.plist
  git commit -m "Release $VERSION"
  git push origin HEAD
fi

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
