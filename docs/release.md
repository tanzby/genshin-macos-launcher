# Releasing

Push a semver tag from `main` (`1.0.0-rc.1`, ..., `1.0.0`). `.github/workflows/release.yaml` builds the arm64 app (ad-hoc signed), packs `Yaagl-<ver>.zip` and `Yaagl-<ver>.dmg`, signs `appcast.xml` with `generate_appcast`, and publishes a regular release (never marked prerelease, so `releases/latest/download/appcast.xml` always points at the newest tag).

- `CFBundleShortVersionString` is the tag. `CFBundleVersion` is `github.run_number`, a plain integer that only grows, so Sparkle ordering never depends on rc suffixes.
- Without the `SPARKLE_ED_PRIVATE_KEY` secret, or while `SUPublicEDKey` in `project.yml` is empty, a tag run is a dry run: it builds and uploads the files as a workflow artifact and publishes nothing. The Actions tab's "Run workflow" is always a dry run.
- Before publishing, `scripts/release/verify-ed-signature.swift` checks the appcast signature against the `SUPublicEDKey` built into the app, so a secret holding the wrong private key fails the run instead of shipping an update every client rejects.
- Debug builds never start the updater.
- Before `1.0.0`, check that a real `rc.N` to `rc.N+1` update works through the live feed.

## EdDSA key (maintainer only, agents never touch it)

The key cannot be rotated without a Developer ID. If it is lost, every user must reinstall by hand.

1. Download `Sparkle-2.10.0.tar.xz` from the Sparkle releases and run `bin/generate_keys`. It stores the private key in the login Keychain and prints the public key.
2. Put the public key into `SUPublicEDKey` in `project.yml` (via PR).
3. Export: `bin/generate_keys -x ~/sparkle_private.key`.
4. Back it up twice: password manager, and an offline encrypted copy.
5. `gh secret set SPARKLE_ED_PRIVATE_KEY < ~/sparkle_private.key`
6. Delete the plaintext: `rm -P ~/sparkle_private.key`
7. Restore drill: in a throwaway user or with a temporary keychain, import a backup with `bin/generate_keys -f <file>`, then run `bin/generate_keys -p` and compare with `SUPublicEDKey`.
