# Paneless Sparkle updates

Approved scope: replace the notification-only update checker with Sparkle 2. Manual checks show Sparkle's UI. Automatic checks and downloads stay quiet, install on quit, and expose an explicit Restart to Update action after staging.

Preserve com.paneless.app, Developer ID team 2WDPP87T4V, Accessibility identity, config, workspace state, customization and the CLI symlink. Use a separate Sparkle Keychain account com.paneless.app. Initial distribution remains the existing Homebrew cask with auto_updates true. An explicit brew upgrade --greedy may still replace the app.

The HTTPS feed is https://github.com/DYNNIwav/paneless/releases/latest/download/appcast.xml. GitHub documents this asset URL form. The existing latest release v0.6.0 contains Paneless.app.zip and has no appcast yet. Each future feed points to a unique archive under that release's immutable tag URL. No Hugin localhost feed is copied.

Release preparation runs tests, builds with two jobs, embeds Sparkle, signs inside out, notarizes, staples, verifies code signatures, signs and verifies the archive, then creates a complete draft release. Only an explicit publication step exposes it as latest. Never delete an existing release, overwrite its assets, push origin, or modify the installed application. A failed preparation leaves the previous public feed intact.

Before release, verify updater actions and lifecycle errors, monotonic build versions, duplicate publication rejection, tamper detection, and a two-release fixture that preserves configuration and the CLI symlink. Independent review precedes installation and publication.
