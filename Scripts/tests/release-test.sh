#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."

# Sourcing is safe on the implemented pipeline; the old script fails before running tools.
source Scripts/release.sh

expect_newer() {
    paneless_build_is_newer "$1" "$2" || { echo "Expected newer build: $1 > $2" >&2; exit 1; }
}
expect_rejected() {
    if paneless_build_is_newer "$1" "$2"; then echo "Accepted invalid build order: $1 <= $2" >&2; exit 1; fi
}

expect_newer 20260930.120001 20260930.120000
expect_newer 20261001.000000 20260930.235959
expect_rejected 20260930.120000 20260930.120000
expect_rejected 20260930.115959 20260930.120000
expect_rejected 20260929.235959 20260930.000000
expect_rejected invalid 20260930.120000
expect_rejected 20260930.120000 invalid

fixture="$(mktemp -d /private/tmp/paneless-release-test.XXXXXX)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/old-public"
printf '%s\n' 'previous verified feed' > "$fixture/old-public/appcast.xml"

archive="$fixture/Paneless-20260930.120001.zip"
printf '%s' verified > "$archive"
feed="$fixture/feed.xml"
write_feed() {
    printf '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>%s</sparkle:version><enclosure url="%s" length="%s" sparkle:edSignature="signature"/></item></channel></rss>' "$3" "$1" "$2" > "$feed"
}
url='https://github.com/DYNNIwav/paneless/releases/download/v0.7.0/Paneless-20260930.120001.zip'
write_feed "$url" 8 20260930.120001
paneless_release_validate_feed "$feed" "$archive" v0.7.0 20260930.120001
for mutation in url length version; do
    case "$mutation" in
        url) write_feed 'https://example.com/changed.zip' 8 20260930.120001 ;;
        length) write_feed "$url" 9 20260930.120001 ;;
        version) write_feed "$url" 8 20260930.120000 ;;
    esac
    if paneless_release_validate_feed "$feed" "$archive" v0.7.0 20260930.120001; then
        echo "Accepted changed feed $mutation" >&2; exit 1
    fi
done

# Recheck at publication time: another prepared release may have become latest.
gh() { printf '%s\n' appcast.xml; }
curl() { cat "$feed"; }
write_feed "$url" 8 20260930.120000
paneless_release_check_latest_build 20260930.120001
if paneless_release_check_latest_build 20260930.120000; then
    echo "Accepted a stale prepared release" >&2; exit 1
fi
unset -f gh curl

mkdir -p "$fixture/notary/Paneless.app/Contents"
printf '%s' fixture > "$fixture/notary/Paneless.app/Contents/fixture"
xcrun() { printf '%s\n' '{"status":"Invalid"}'; }
if paneless_release_notarize v0.7.0 "$fixture/notary" 20260930.120001; then
    echo "Accepted rejected notarization with a successful tool exit" >&2; exit 1
fi
xcrun() { printf '%s\n' '{"status":"Accepted"}'; }
paneless_release_notarize v0.7.0 "$fixture/notary" 20260930.120001
unset -f xcrun

paneless_release_cask v0.7.0 20260930.120001 abc123 > "$fixture/paneless.rb"
rg -Fq 'auto_updates true' "$fixture/paneless.rb"
rg -Fq 'depends_on arch: :arm64' "$fixture/paneless.rb"
rg -Fq 'depends_on macos: :sonoma' "$fixture/paneless.rb"
rg -Fq 'Paneless-20260930.120001.zip' "$fixture/paneless.rb"
rg -Fq 'target: "paneless"' "$fixture/paneless.rb"

# The real orchestration is exercised with controlled external stage boundaries.
paneless_release_preflight() { printf 'preflight\n' >> "$fixture/stages"; test "${FAIL_STAGE:-}" != preflight; }
paneless_release_test() { printf 'test\n' >> "$fixture/stages"; test "${FAIL_STAGE:-}" != test; }
paneless_release_build() { printf 'build\n' >> "$fixture/stages"; test "${FAIL_STAGE:-}" != build; }
paneless_release_sign() { printf 'sign\n' >> "$fixture/stages"; test "${FAIL_STAGE:-}" != sign; }
paneless_release_notarize() { printf 'notarize\n' >> "$fixture/stages"; test "${FAIL_STAGE:-}" != notarize; }
paneless_release_staple() { printf 'staple\n' >> "$fixture/stages"; test "${FAIL_STAGE:-}" != staple; }
paneless_release_verify() { printf 'verify\n' >> "$fixture/stages"; test "${FAIL_STAGE:-}" != verify; }
paneless_release_archive() { printf 'archive\n' >> "$fixture/stages"; test "${FAIL_STAGE:-}" != archive; }
paneless_release_feed() { printf 'feed\n' >> "$fixture/stages"; test "${FAIL_STAGE:-}" != feed; }

old_feed="$(shasum -a 256 "$fixture/old-public/appcast.xml")"
for stage in preflight test build sign notarize staple verify archive feed; do
    : > "$fixture/stages"
    if FAIL_STAGE="$stage" paneless_release_prepare v0.7.0 "$fixture/prepared-$stage"; then
        echo "Preparation ignored failure at $stage" >&2
        exit 1
    fi
    test "$old_feed" = "$(shasum -a 256 "$fixture/old-public/appcast.xml")"
    test "$(tail -1 "$fixture/stages")" = "$stage"
done

: > "$fixture/stages"
paneless_release_prepare v0.7.0 "$fixture/prepared-success"
expected=$'preflight\ntest\nbuild\nsign\nnotarize\nstaple\nverify\narchive\nfeed'
test "$(< "$fixture/stages")" = "$expected"
test "$old_feed" = "$(shasum -a 256 "$fixture/old-public/appcast.xml")"

echo "Paneless release ordering and failure gates passed"
