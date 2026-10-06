#!/bin/bash
# Two-release artifact contract, never installs or launches either temporary app.
set -euo pipefail
cd "$(dirname "$0")/../.."
source Scripts/release.sh
bundle="${1:-$PANELESS_RELEASE_ROOT/Paneless.app}"
tools="$PANELESS_RELEASE_ROOT/.build/artifacts/sparkle/Sparkle/bin"
fixture="$(mktemp -d /private/tmp/paneless-update-artifacts.XXXXXX)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/home/.config/paneless" "$fixture/Applications" "$fixture/bin" "$fixture/releases"
printf 'gap = 13\ncustom = true\n' > "$fixture/home/.config/paneless/config"
printf '{"workspace":7}' > "$fixture/home/.config/paneless/workspaces.json"
ln -s "$fixture/Applications/Paneless.app/Contents/MacOS/Paneless" "$fixture/bin/paneless"
before="$(shasum -a 256 "$fixture/home/.config/paneless/"*)"

for build in 20260930.120000 20260930.120001; do
    directory="$fixture/$build"
    mkdir "$directory"
    ditto "$bundle" "$directory/Paneless.app"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build" "$directory/Paneless.app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 0.7.0' "$directory/Paneless.app/Contents/Info.plist"
    paneless_release_sign v0.7.0 "$directory" "$build"
    codesign --verify --deep --strict "$directory/Paneless.app"
    codesign -dr - "$directory/Paneless.app" 2>&1 | sed -n '/^designated =>/p' > "$directory/requirement"
    [ -s "$directory/requirement" ]
    paneless_release_archive v0.7.0 "$directory" "$build"
    cp "$directory/Paneless-$build.zip" "$fixture/releases/"
done

cmp "$fixture/20260930.120000/requirement" "$fixture/20260930.120001/requirement"
"$tools/generate_appcast" --account "$PANELESS_SPARKLE_ACCOUNT" --maximum-deltas 0 \
    --download-url-prefix 'https://github.com/DYNNIwav/paneless/releases/download/v0.7.0/' "$fixture/releases"
count="$(xmllint --xpath 'count(//*[local-name()="enclosure"])' "$fixture/releases/appcast.xml")"
[ "$count" = 2 ]
for build in 20260930.120000 20260930.120001; do
    signature="$(xmllint --xpath "string(//*[local-name()='item'][*[local-name()='version']='$build']/*[local-name()='enclosure']/@*[local-name()='edSignature'])" "$fixture/releases/appcast.xml")"
    "$tools/sign_update" --account "$PANELESS_SPARKLE_ACCOUNT" --verify "$fixture/releases/Paneless-$build.zip" "$signature"
done
printf 'changed' >> "$fixture/releases/Paneless-20260930.120001.zip"
if "$tools/sign_update" --account "$PANELESS_SPARKLE_ACCOUNT" --verify "$fixture/releases/Paneless-20260930.120001.zip" "$signature"; then
    echo 'Accepted a changed signed archive' >&2; exit 1
fi

# Simulate replacing only the application payload. Real Sparkle installation is a separate gate.
ditto "$fixture/20260930.120000/Paneless.app" "$fixture/Applications/Paneless.app"
ditto "$fixture/20260930.120001/Paneless.app" "$fixture/Applications/Paneless.app"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$fixture/Applications/Paneless.app/Contents/Info.plist")" = 20260930.120001 ]
[ "$before" = "$(shasum -a 256 "$fixture/home/.config/paneless/"*)" ]
[ -x "$fixture/bin/paneless" ]
[ "$(readlink "$fixture/bin/paneless")" = "$fixture/Applications/Paneless.app/Contents/MacOS/Paneless" ]
echo 'Two signed releases, archive tamper rejection, stable identity, config and CLI symlink contracts passed'
