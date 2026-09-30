# Paneless Sparkle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task by task. Steps use checkbox syntax for tracking.

**Goal:** Make Paneless update quietly through verified Sparkle releases while preserving its existing app identity and user state.

**Architecture:** A small PanelessUpdater owns one Sparkle controller, a staged installation callback, and menu actions. Release preparation is local and fails closed; publication is a separate explicit operation against a complete draft.

**Tech Stack:** Swift, AppKit, Sparkle 2.9.6, Bash, existing Developer ID and notarytool.

**Spec:** docs/superpowers/specs/2026-09-30-paneless-sparkle.md (the already approved design).

## Global Constraints

- Start from 41ff3dd in feature/sparkle-updater, preserve others' edits.
- Preserve com.paneless.app and Developer ID team 2WDPP87T4V.
- No AppleScript, attribution lines, origin pushes, installation or public publication.
- HTTPS GitHub release asset feed, separate com.paneless.app EdDSA account, unique immutable archives.
- Compiler belongs to the Hugin release worker until explicitly handed back; queue all Swift runs.

## Review Focus

- A failed check must discard an expired restart callback.
- Repeated manual checks must not launch duplicate update cycles.
- A malformed or tampered archive must never reach publication.
- Equal or regressing build numbers must never replace the feed.
- Config, workspaces, customization and the CLI symlink must survive two app replacements.

## Task 1: Updater and native menu

**Files:** Create Sources/Paneless/PanelessUpdater.swift and Tests/PanelessTests/UpdaterTests.swift; modify Package.swift, PanelessApp.swift, Resources/Info.plist and Scripts/build.sh; remove UpdateChecker.swift.

**Interfaces:** PanelessUpdater.start(info:), menuItem(), validateMenuItem(_:), stage(version:install:), ended(error:). The Sparkle delegates call stage and ended. Tests inject check and canCheck closures at the external framework boundary.

- [ ] Write tests before production code. Manual checks increment once; a duplicate is ignored until ended; staging enables Restart to Update; restart invokes the staged callback; errors clear the callback; no feed disables the updater; no stage or check mutates app configuration.

```swift
var checks = 0
let updater = PanelessUpdater(check: { checks += 1 }, canCheck: { true })
updater.request()
updater.request()
#expect(checks == 1)
updater.ended(error: nil)
updater.request()
#expect(checks == 2)
```

- [ ] After compiler handoff, run `swift test --jobs 2 --filter UpdaterTests`; expect missing PanelessUpdater to fail first.
- [ ] Implement the controller and delegate boundary with one staged callback; use canCheckForUpdates and a local pending flag, suppress scheduled reminders, preserve manual Sparkle UI.
- [ ] Add exact Sparkle dependency, framework rpath and inside-out framework signing. Generate only Paneless's own Keychain key, embed its public half and never export the private key.
- [ ] Run the whole Swift suite and bundle verification; expect no failures, unchanged bundle identifier and team.
- [ ] Commit the updater and its tests together.

## Task 2: Verified release preparation

**Files:** Modify Scripts/release.sh; create Scripts/tests/release-test.sh and Scripts/release-verify.swift; document distribution in README.md.

**Interfaces:** `paneless_release_prepare(version, output)` creates local immutable archive and feed only after all verification succeeds. `paneless_release_publish(directory)` uploads a complete draft, validates its expected asset names, and publishes it only when explicitly requested. Neither interface pushes source branches or overwrites releases.

- [ ] Write command-boundary tests that substitute controlled tools and run the real script. Reject dirty source, invalid versions, same build number, existing release, missing public key, failed tests/build/sign/notarization/staple/archive verification/signature verification. Every rejection must leave the old feed and publication log unchanged.

```bash
old_feed="$(shasum -a 256 "$fixture/public/appcast.xml")"
if FAIL_STAGE=notarize paneless_release_prepare v0.7.0 "$fixture/prepared"; then exit 1; fi
test "$old_feed" = "$(shasum -a 256 "$fixture/public/appcast.xml")"
test ! -s "$fixture/published"
```

- [ ] Run the shell tests and observe missing prepare functions before implementation.
- [ ] Replace release deletion and origin pushes with a locally prepared archive, build number, signed feed and metadata. Reuse Sparkle generate_appcast/sign_update, Developer ID identity resolver, notarytool and stapler; retain the separate Keychain account.
- [ ] Run stage-failure tests and real archive signature verification. Tampering with one byte must reject the archive. Run two monotonically ordered fixture releases; expect both unique archive names and tag-specific HTTPS enclosure URLs.
- [ ] Commit the release pipeline and tests together.

## Task 3: Compatibility and review gate

**Files:** Create Scripts/tests/update-preservation-test.sh; update README.md with cask handoff instructions.

**Interfaces:** The fixture replaces only an app directory. User config/state directories and a symlink to the installed executable are external to the replacement.

- [ ] Write and run a two-release replacement test with custom config, workspace and customization bytes, plus a CLI symlink. Assert their independent hashes and link target before and after two replacements.
- [ ] Check the cask template retains the app and binary stanza and adds auto_updates true. Explain that explicit greedy Homebrew upgrades may still overwrite a self-updated app.
- [ ] Run all Swift and shell tests with two compiler jobs, verify final bundle signatures and preservation evidence, then commit.
- [ ] Request independent whole-branch review. No install or public publish before the review and release authorization.
