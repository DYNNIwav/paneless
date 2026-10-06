#!/bin/bash
set -euo pipefail

PANELESS_RELEASE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PANELESS_RELEASE_REPO=DYNNIwav/paneless
PANELESS_SPARKLE_ACCOUNT=com.paneless.app

paneless_build_is_newer() {
    [[ "$1" =~ ^[0-9]{8}\.[0-9]{6}$ && "$2" =~ ^[0-9]{8}\.[0-9]{6}$ ]] || return 1
    awk -v candidate="$1" -v previous="$2" 'BEGIN {
        split(candidate, a, "."); split(previous, b, ".")
        exit !(a[1] > b[1] || (a[1] == b[1] && a[2] > b[2]))
    }'
}

paneless_release_validate_feed() {
    local feed="$1" archive="$2" version="$3" build="$4" count url length feed_build
    count="$(/usr/bin/xmllint --xpath 'count(//*[local-name()="enclosure"])' "$feed")" || return 1
    [ "$count" = 1 ] || return 1
    url="$(/usr/bin/xmllint --xpath 'string(//*[local-name()="enclosure"]/@url)' "$feed")" || return 1
    length="$(/usr/bin/xmllint --xpath 'string(//*[local-name()="enclosure"]/@length)' "$feed")" || return 1
    feed_build="$(/usr/bin/xmllint --xpath 'string(//*[local-name()="item"]/*[local-name()="version"])' "$feed")" || return 1
    [ "$url" = "https://github.com/$PANELESS_RELEASE_REPO/releases/download/$version/Paneless-$build.zip" ] &&
        [ "$length" = "$(stat -f %z "$archive")" ] && [ "$feed_build" = "$build" ]
}

paneless_release_check_latest_build() {
    local build="$1" assets previous
    assets="$(gh api "repos/$PANELESS_RELEASE_REPO/releases/latest" --jq '.assets[].name')" || return 1
    if printf '%s\n' "$assets" | grep -Fxq appcast.xml; then
        previous="$(curl --fail --silent --show-error --location "https://github.com/$PANELESS_RELEASE_REPO/releases/latest/download/appcast.xml" \
            | /usr/bin/xmllint --xpath 'string(//*[local-name()="item"]/*[local-name()="version"])' -)" || return 1
        paneless_build_is_newer "$build" "$previous" || { echo "Build $build is not newer than $previous" >&2; return 1; }
    fi
}

paneless_release_preflight() {
    local version="$1" output="$2" build="$3" tags public key
    [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Use a version such as v0.7.0" >&2; return 1; }
    [ ! -e "$output" ] || { echo "Release directory already exists: $output" >&2; return 1; }
    [ -z "$(git -C "$PANELESS_RELEASE_ROOT" status --porcelain)" ] || { echo "Commit source changes before preparing a release" >&2; return 1; }
    tags="$(gh api "repos/$PANELESS_RELEASE_REPO/releases" --paginate --jq '.[].tag_name')" || return 1
    if printf '%s\n' "$tags" | grep -Fxq "$version"; then echo "Release already exists: $version" >&2; return 1; fi
    public="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PANELESS_RELEASE_ROOT/Resources/Info.plist")" || return 1
    key="$("$PANELESS_RELEASE_ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_keys" --account "$PANELESS_SPARKLE_ACCOUNT" -p)" || return 1
    [ -n "$public" ] && [ "$public" = "$key" ] || { echo "Public key does not match Paneless's Keychain signing account" >&2; return 1; }
    paneless_release_check_latest_build "$build"
}

paneless_release_test() {
    (cd "$PANELESS_RELEASE_ROOT" && swift test --jobs 2 && bash Scripts/tests/release-test.sh)
}

paneless_release_build() {
    local version="$1" output="$2" build="$3"
    (cd "$PANELESS_RELEASE_ROOT" && bash Scripts/build.sh) || return 1
    /usr/bin/ditto "$PANELESS_RELEASE_ROOT/Paneless.app" "$output/Paneless.app" || return 1
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${version#v}" "$output/Paneless.app/Contents/Info.plist" || return 1
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build" "$output/Paneless.app/Contents/Info.plist"
}

paneless_release_sign() {
    local app="$2/Paneless.app" sparkle identity
    source "$PANELESS_RELEASE_ROOT/Scripts/signing-identity.sh"
    identity="$(paneless_developer_id_hash)" || return 1
    [ -n "$identity" ] || { echo "No usable Developer ID Application certificate" >&2; return 1; }
    sparkle="$app/Contents/Frameworks/Sparkle.framework"
    [ -d "$sparkle" ] || { echo "Sparkle framework missing" >&2; return 1; }
    codesign --force --options runtime --sign "$identity" "$sparkle/Versions/B/Autoupdate" || return 1
    codesign --force --options runtime --sign "$identity" "$sparkle/Versions/B/Updater.app" || return 1
    codesign --force --options runtime --sign "$identity" "$sparkle" || return 1
    codesign --force --options runtime --identifier com.paneless.app --sign "$identity" "$app"
}

paneless_release_notarize() {
    local status
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$2/Paneless.app" "$2/notary.zip" || return 1
    xcrun notarytool submit "$2/notary.zip" --keychain-profile paneless-notarize --wait --output-format json > "$2/notary-result.json" || return 1
    status="$(plutil -extract status raw -o - "$2/notary-result.json")" || return 1
    [ "$status" = Accepted ] || { echo "Notarization was not accepted: $status" >&2; return 1; }
}

paneless_release_staple() {
    xcrun stapler staple "$2/Paneless.app" && xcrun stapler validate "$2/Paneless.app"
}

paneless_release_verify() {
    local app="$2/Paneless.app" identity
    codesign --verify --deep --strict "$app" || return 1
    identity="$(codesign -dv --verbose=4 "$app" 2>&1)" || return 1
    printf '%s\n' "$identity" | grep -Fxq 'Identifier=com.paneless.app' || return 1
    printf '%s\n' "$identity" | grep -Fxq 'TeamIdentifier=2WDPP87T4V' || return 1
    spctl --assess --type execute "$app" || return 1
    bash "$PANELESS_RELEASE_ROOT/Scripts/tests/update-artifact-test.sh" "$app"
}

paneless_release_archive() {
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$2/Paneless.app" "$2/Paneless-$3.zip"
}

paneless_release_cask() {
    printf 'cask "paneless" do\n  version "%s"\n  sha256 "%s"\n' "${1#v}" "$3"
    printf '  url "https://github.com/%s/releases/download/%s/Paneless-%s.zip"\n' "$PANELESS_RELEASE_REPO" "$1" "$2"
    printf '  name "Paneless"\n  desc "Tiling window manager"\n  homepage "https://github.com/%s"\n' "$PANELESS_RELEASE_REPO"
    printf '  auto_updates true\n  depends_on arch: :arm64\n  depends_on macos: :sonoma\n  app "Paneless.app"\n'
    printf '  binary "#{appdir}/Paneless.app/Contents/MacOS/Paneless", target: "paneless"\nend\n'
}

paneless_release_feed() {
    local version="$1" output="$2" build="$3" tools signature archive sha
    tools="$PANELESS_RELEASE_ROOT/.build/artifacts/sparkle/Sparkle/bin"
    archive="$output/Paneless-$build.zip"
    mkdir "$output/notarization" || return 1
    mv "$output/notary.zip" "$output/notarization/upload.zip" || return 1
    "$tools/generate_appcast" --account "$PANELESS_SPARKLE_ACCOUNT" --maximum-deltas 0 \
        --download-url-prefix "https://github.com/$PANELESS_RELEASE_REPO/releases/download/$version/" "$output" || return 1
    signature="$(/usr/bin/xmllint --xpath 'string(//*[local-name()="enclosure"]/@*[local-name()="edSignature"])' "$output/appcast.xml")" || return 1
    paneless_release_validate_feed "$output/appcast.xml" "$archive" "$version" "$build" || return 1
    [ -n "$signature" ] || return 1
    "$tools/sign_update" --account "$PANELESS_SPARKLE_ACCOUNT" --verify "$archive" "$signature" || return 1
    sha="$(shasum -a 256 "$archive" | awk '{print $1}')" || return 1
    paneless_release_cask "$version" "$build" "$sha" > "$output/paneless.rb" || return 1
    printf '%s\n' "$version" "$build" "$sha" "$(git -C "$PANELESS_RELEASE_ROOT" rev-parse HEAD)" > "$output/release.txt"
    printf 'Prepared %s (%s) in %s. Nothing published.\n' "$version" "$build" "$output"
}

paneless_release_prepare() {
    local version="$1" output="$2" build
    build="$(date -u +%Y%m%d.%H%M%S)"
    paneless_release_preflight "$version" "$output" "$build" || return 1
    mkdir -p "$output" || return 1
    paneless_release_test "$version" "$output" "$build" || return 1
    paneless_release_build "$version" "$output" "$build" || return 1
    paneless_release_sign "$version" "$output" "$build" || return 1
    paneless_release_notarize "$version" "$output" "$build" || return 1
    paneless_release_staple "$version" "$output" "$build" || return 1
    paneless_release_verify "$version" "$output" "$build" || return 1
    paneless_release_archive "$version" "$output" "$build" || return 1
    paneless_release_feed "$version" "$output" "$build" || return 1
}

paneless_release_publish() {
    local output="$1" version build sha commit archive signature tools assets actual
    [ -f "$output/release.txt" ] || { echo "Verified release metadata missing" >&2; return 1; }
    version="$(sed -n '1p' "$output/release.txt")"
    build="$(sed -n '2p' "$output/release.txt")"
    sha="$(sed -n '3p' "$output/release.txt")"
    commit="$(sed -n '4p' "$output/release.txt")"
    [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && "$build" =~ ^[0-9]{8}\.[0-9]{6}$ && "$commit" =~ ^[0-9a-f]{40}$ ]] || return 1
    archive="$output/Paneless-$build.zip"
    actual="$(shasum -a 256 "$archive" | awk '{print $1}')" || return 1
    [ "$actual" = "$sha" ] || { echo "Prepared archive changed" >&2; return 1; }
    tools="$PANELESS_RELEASE_ROOT/.build/artifacts/sparkle/Sparkle/bin"
    signature="$(/usr/bin/xmllint --xpath 'string(//*[local-name()="enclosure"]/@*[local-name()="edSignature"])' "$output/appcast.xml")" || return 1
    paneless_release_validate_feed "$output/appcast.xml" "$archive" "$version" "$build" || return 1
    "$tools/sign_update" --account "$PANELESS_SPARKLE_ACCOUNT" --verify "$archive" "$signature" || return 1
    paneless_release_check_latest_build "$build" || return 1
    gh api "repos/$PANELESS_RELEASE_REPO/commits/$commit" > /dev/null || return 1
    gh release create "$version" "$archive" "$output/appcast.xml" --repo "$PANELESS_RELEASE_REPO" \
        --draft --target "$commit" --title "Paneless $version" --generate-notes || return 1
    assets="$(gh release view "$version" --repo "$PANELESS_RELEASE_REPO" --json assets --jq '.assets[].name')" || return 1
    printf '%s\n' "$assets" | grep -Fxq "Paneless-$build.zip" || return 1
    printf '%s\n' "$assets" | grep -Fxq appcast.xml || return 1
    gh release edit "$version" --repo "$PANELESS_RELEASE_REPO" --draft=false --latest
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    cd "$PANELESS_RELEASE_ROOT"
    case "${1:-}" in
        --prepare)
            [ "$#" -eq 3 ] || { echo "Usage: $0 --prepare vX.Y.Z /absolute/output" >&2; exit 1; }
            [[ "$3" = /* ]] || { echo "Use an absolute output path" >&2; exit 1; }
            paneless_release_prepare "$2" "$3"
            ;;
        --publish)
            [ "$#" -eq 2 ] || { echo "Usage: $0 --publish /absolute/prepared-directory" >&2; exit 1; }
            paneless_release_publish "$2"
            ;;
        *) echo "Use --prepare vX.Y.Z /absolute/output, then --publish /absolute/output after review" >&2; exit 1 ;;
    esac
fi
