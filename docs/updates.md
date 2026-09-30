# Paneless updates

Homebrew remains the initial installation path. The generated cask keeps the
`paneless` CLI symlink and declares `auto_updates true`. Sparkle checks quietly,
downloads signed updates and installs on quit. The menu offers Check for Updates
and changes to Restart to Update when an update is staged.

An explicit `brew upgrade --greedy` can still replace a self-updated app. This is
not a guarantee of exclusive ownership between Homebrew and Sparkle.

Release preparation is local and does not change the public feed:

```sh
bash Scripts/release.sh --prepare v0.7.0 /private/tmp/paneless-v0.7.0
```

Preparation requires a clean committed source tree, the Paneless-specific
`com.paneless.app` EdDSA Keychain identity, Developer ID team `2WDPP87T4V`, and the
`paneless-notarize` notary profile. Every stage stops on failure. Archives use a
unique UTC build number, and the feed references immutable tag-specific assets.
The prepared `paneless.rb` is the cask update, it is not automatically committed
or published to the tap.

After independent review and release authorization, publish separately:

```sh
bash Scripts/release.sh --publish /private/tmp/paneless-v0.7.0
```

Publishing rechecks archive integrity, EdDSA signature, feed metadata and latest
build order before creating a draft. The source commit must already exist on
GitHub, the script never pushes it. Only a complete draft becomes latest, so a
failed preparation or upload leaves the previous public feed intact.

The feed URL is GitHub's supported latest-release asset link:
`https://github.com/DYNNIwav/paneless/releases/latest/download/appcast.xml`.
It first exists when the first Sparkle-enabled release is published.

Verification:

```sh
swift test --jobs 2
bash Scripts/tests/release-test.sh
bash Scripts/build.sh
bash Scripts/tests/update-artifact-test.sh
```

The two-release artifact test signs temporary app copies, verifies EdDSA archives,
rejects tampering, compares designated requirements and checks synthetic config
and CLI symlink preservation. It never launches or installs an app. A real
Sparkle installation, live Accessibility grant retention and notarized release
assessment remain release gates, not claims made by this fixture test.
