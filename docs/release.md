# Releasing

Push a semver tag from `main` (`1.0.0-rc.1`, ..., `1.0.0`). `.github/workflows/release.yaml` builds the arm64 app (ad-hoc signed), packs `GenshinLauncher-<ver>.dmg` with `scripts/release/make-dmg`, signs `appcast.xml` with `generate_appcast`, and publishes a regular release (never marked prerelease, so `releases/latest/download/appcast.xml` always points at the newest tag).

- The DMG is the only download: people install from it, and it is the appcast enclosure (see `scripts/release/make-dmg`). It carries `安装说明.txt` from `scripts/release/dmg-install.txt`, which is also the top of the release notes.
- The app is ad-hoc signed and not notarized, so a downloaded copy is blocked on first launch until the user allows it once. Only a Developer ID signature plus notarization removes that prompt; it needs a paid Apple Developer account.
- `CFBundleShortVersionString` is the tag. `CFBundleVersion` is `github.run_number`, a plain integer that only grows, so Sparkle ordering never depends on rc suffixes.
- Without the `SPARKLE_ED_PRIVATE_KEY` secret, or while `SUPublicEDKey` in `project.yml` is empty, a tag run is a dry run: it builds and uploads the files as a workflow artifact and publishes nothing. The Actions tab's "Run workflow" is always a dry run.
- Before publishing, `scripts/release/verify-ed-signature.swift` checks the appcast signature against the `SUPublicEDKey` built into the app, so a secret holding the wrong private key fails the run instead of shipping an update every client rejects.
- Debug builds never start the updater.
- The app ships `SUEnableAutomaticChecks=true` and `SUScheduledCheckInterval=86400` (checked by `scripts/dev/check-bundle`), so it checks daily without Sparkle's permission prompt. The Settings toggle writes the user default, which wins over the plist. The "Check for Updates…" menu item is disabled while `SPUUpdater.canCheckForUpdates` is false.
- Only the final version is published. The update path is verified locally, before tagging, with `scripts/dev/sparkle-local-check` (below); release candidates are not cut for it.

## Local update check (before tagging 1.0.0)

`scripts/dev/sparkle-local-check` builds two copies of the current commit (`1.0.0-test.1` build 9001, `1.0.0-test.2` build 9002) and packs the second one into a release DMG (`scripts/release/make-dmg`) signed with a throwaway key kept in a file (never the release key, never the Keychain). Both copies get the test public key and a feed on `http://127.0.0.1:18765/appcast.xml` (plain http for the test copies only, `project.yml` is untouched). It serves the feed, installs test.1 under `~/Library/Caches/genshin-launcher-sparkle-test/` with its data directory there too, and starts it.

1. Run `scripts/dev/sparkle-local-check`. It stops at "waiting for a click".
2. In test.1 choose Genshin Launcher > Check for Updates…. Sparkle must offer 1.0.0-test.2, install it and relaunch; About shows test.2. This must work with the first-launch onboarding sheet open.
3. Settings shows "Automatically check for updates" on. Turn it off, quit, relaunch: it stays off.
4. Run `scripts/dev/sparkle-local-check stop`: it stops the server and the app, unsets `GENSHIN_LAUNCHER_DATA_DIR` and restores the Sparkle keys of the preference domain.

The test copies have no DXMT unless `scripts/build-dxmt` ran in the checkout, so "Set up Wine" fails in them ("无法完成 Wine 的设置"); the update check does not need Wine, and a release build always carries DXMT (`release.yaml` builds it and runs `check-bundle` with `REQUIRE_DXMT=1`).

The data directory reaches the relaunched app through `launchctl setenv GENSHIN_LAUNCHER_DATA_DIR`, because Sparkle relaunches without command-line arguments. The test copies share the bundle id, and so the preference domain, with the real app; the script saves the Sparkle (`SU*`) keys before the test and `stop` puts them back. The real app in `/Applications` and `~/Library/Application Support/Genshin Launcher` are never touched.

## EdDSA key (maintainer only, agents never touch it)

The key cannot be rotated without a Developer ID. If it is lost, every user must reinstall by hand.

1. Download `Sparkle-2.10.0.tar.xz` from the Sparkle releases and run `bin/generate_keys`. It stores the private key in the login Keychain and prints the public key.
2. Put the public key into `SUPublicEDKey` in `project.yml` (via PR).
3. Export: `bin/generate_keys -x ~/sparkle_private.key`.
4. Back it up twice: password manager, and an offline encrypted copy.
5. `gh secret set SPARKLE_ED_PRIVATE_KEY < ~/sparkle_private.key`
6. Delete the plaintext: `rm -P ~/sparkle_private.key`
7. Restore drill: in a throwaway user or with a temporary keychain, import a backup with `bin/generate_keys -f <file>`, then run `bin/generate_keys -p` and compare with `SUPublicEDKey`.
