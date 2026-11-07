# Releases and updates

Pressay ships from one workflow, [`release.yml`](../.github/workflows/release.yml). Pushing a `vX.Y.Z` tag builds macOS, Windows and Linux, signs every update, and publishes one GitHub release marked latest.

## Publish

1. Set the same version in `apps/desktop/src-tauri/tauri.conf.json`, the workspace `Cargo.toml` and `apps/desktop/package.json`. Packaging fails if they differ.
2. Merge the tested change, then push the matching tag, for example `v2.0.0`. A tag that doesn't match `tauri.conf.json` fails the build.
3. The workflow builds on three runners:
   - macOS arm64: the app, the DMG, the updater archive, and the ZIP for the 1.x migration feed.
   - Windows x64: the NSIS installer.
   - Linux x64: the AppImage and the `.deb`.

   Each runner runs the tests, OS-signs where configured, then signs the updater artifacts.
4. A final job verifies every signature, writes `desktop-latest.json` and `DESKTOP-SHA256SUMS`, creates the GitHub release, then replaces `desktop-latest.json` on the permanent `desktop-updates` release.

Release assets:

| File | Purpose |
| --- | --- |
| `Pressay-<version>-macos-arm64.dmg` | Mac manual install |
| `Pressay-<version>-macos-arm64.app.tar.gz` + `.sig` | Mac in-app update |
| `Pressay-<version>-windows-x86_64-setup.exe` + `.sig` | Windows install and update |
| `Pressay-<version>-linux-x86_64.AppImage` + `.sig` | Linux install and update |
| `Pressay-<version>-linux-x86_64.deb` + `.sig` | Debian/Ubuntu install and update |
| `Pressay-macos-arm64.zip`, `appcast.xml`, `SHA256SUMS` | `scripts/install.sh` and the update path for Pressay 1.x |
| `DESKTOP-SHA256SUMS` | Checksums for the files above |

Do not edit or replace an archive after it is signed. Each release needs a higher version.

## In-app updates

The app checks `https://github.com/Zheruel/pressay-macos/releases/download/desktop-updates/desktop-latest.json` when you choose **Check for updates** under **Settings › General › App updates**. The `desktop-updates` release is created once with `--latest=false` and only its feed is replaced; installer URLs point at the versioned release. Package-specific targets keep `.deb` users on `.deb` updates.

Pressay refuses to install while a dictation, recording or model preparation is running, including one started during the download.

### Updater signing key

Tauri update signatures are separate from Apple and Windows code signing. The workflow needs:

| Name | Kind | Contents |
| --- | --- | --- |
| `TAURI_SIGNING_PRIVATE_KEY` | Secret | Private key file contents |
| `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` | Secret | Its password |
| `PRESSAY_UPDATE_PUBLIC_KEY` | Variable | Public `.pub` contents, compiled into the app |

To create a key with the pinned CLI:

```sh
cd apps/desktop
npm ci
npx tauri signer generate --write-keys /secure/path/pressay-desktop.key
```

Keep a secure backup of the key and never commit it. Replacing it without a migration stops existing installs from accepting updates.

Before building, the workflow signs a probe and checks it against the public key. Final artifacts are signed after OS signing. Each `.sig` carries the app version in its trusted comment, and the app requires it to match the feed. The publish job verifies every signature with libsodium and fails if a platform is missing.

## Updating Pressay 1.x (Swift app)

Macs on Pressay 1.x update through Sparkle from `releases/latest/download/appcast.xml`. The macOS runner downloads the pinned Sparkle release, uses only its `generate_appcast` tool to sign `Pressay-macos-arm64.zip` with the 1.x key, and verifies the feed before publishing ([`scripts/sparkle-bridge.py`](../scripts/sparkle-bridge.py)). This needs the `SPARKLE_PRIVATE_KEY` secret. Sparkle is not bundled in the app.

Sparkle orders updates by `CFBundleVersion`. Packaging sets it to `major × 10000 + minor × 100 + patch` (20000 for 2.0.0), above the last 1.x build (26).

The app keeps the `dev.localflow.app` bundle identifier and the same signing certificate, so macOS permissions carry over. On first launch it imports the 1.x dictation history, meeting notes and settings, read-only. API keys and original audio stay explicit imports in **Settings › General**. Rollback is reinstalling 1.14.2, whose data is untouched.

## Mac signing

Releases are signed with the self-signed **Pressay Release Signing** certificate, the same one 1.x used. Create it with `scripts/create-release-signing-certificate.sh`; it stores the certificate in `RELEASE_SIGNING_CERTIFICATE` and its password in `RELEASE_SIGNING_PASSWORD`. Keep a secure backup: a new identity makes users approve permissions again. These builds are not notarized, and the release notes say so.

### Notarization

To notarize, sign with a **Developer ID Application** certificate (exported as a password-protected `.p12`, base64 in `RELEASE_SIGNING_CERTIFICATE`, password in `RELEASE_SIGNING_PASSWORD`) and set the repository variable `PRESSAY_NOTARIZE` to `1`. Add these secrets from an App Store Connect API key:

| Secret | Contents |
| --- | --- |
| `APPLE_NOTARY_KEY` | The `.p8` private key text |
| `APPLE_NOTARY_KEY_ID` | The API key identifier |
| `APPLE_NOTARY_ISSUER` | The API issuer identifier |

With `PRESSAY_NOTARIZE=1`, the workflow requires Developer ID and never falls back to self-signing. It notarizes and staples the app, then the DMG; the updater archive and ZIP are made from the stapled app. Moving from self-signing to Developer ID changes the signing identity, so existing users approve permissions once more.

Credentials go into a temporary keychain that is deleted even when the build fails. Packaging signs every nested worker and library with hardened runtime. `scripts/verify-macos-deployment.py` rejects any binary that needs a newer macOS than the app's minimum (26.0).

For a local notarized DMG, store `notarytool` credentials and pass the profile name:

```bash
xcrun notarytool store-credentials pressay
APPLE_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
  PRESSAY_NOTARIZE=1 PRESSAY_NOTARY_PROFILE=pressay python3 scripts/build-desktop.py
```

Set `PRESSAY_NOTARY_KEYCHAIN` too if the profile is in a non-default keychain.

### DMG artwork

The DMG opens a 660 × 400 pt window with 128 pt app and Applications icons at `(170, 178)` and `(490, 178)`. `packaging/macos/dmg/render-background.m` draws the background at 1× and 2×. `scripts/package-dmg.sh` builds it with pinned `dmgbuild` tools in `.build/dmg-tools`, then mounts the image read-only to check the Applications link, background, icon positions and app signature. It needs no Finder automation or signed-in session.

## Windows signing

Without configuration, Windows installers are unsigned and SmartScreen may warn. To sign them, the workflow uses Microsoft's [Artifact Signing action](https://github.com/Azure/artifact-signing-action) with OIDC. This needs an Azure subscription, completed identity validation, a **public-trust** certificate profile, and an application with a federated identity for this repository that has the **Artifact Signing Certificate Profile Signer** role. No private key is exported to GitHub.

Set these repository variables: `PRESSAY_AZURE_CLIENT_ID`, `PRESSAY_AZURE_TENANT_ID`, `PRESSAY_AZURE_SUBSCRIPTION_ID`, `PRESSAY_AZURE_SIGNING_ENDPOINT`, `PRESSAY_AZURE_SIGNING_ACCOUNT` and `PRESSAY_AZURE_CERTIFICATE_PROFILE`. The endpoint must match the signing account's region. Signing turns on when `PRESSAY_AZURE_SIGNING_ACCOUNT` is set. The action signs the workers and libraries; Tauri's signing hook signs the main executable, uninstaller and installer. Packaging rejects untrusted or untimestamped signatures. A valid signature does not mean SmartScreen already trusts a new app.

## Local builds

`make app` (or `python3 scripts/build-desktop.py`) builds installers into `target/release/bundle` with no updater, Apple or Microsoft credentials. On a Mac it signs ad hoc unless `APPLE_SIGNING_IDENTITY` is set. The manual **Desktop preview installers** workflow builds all three platforms without publishing.

## Verify before distributing

Install each platform's release on a clean machine or VM, then update to a higher version. Check that **Check for updates** finds it, the restart, kept settings, notes and models, and recovery from a failed download. Start a dictation or meeting before installing an update and confirm Pressay refuses until it ends.

On a Mac, also update from Pressay 1.14.2 through Sparkle: check that Microphone, Accessibility and System Audio Recording carry over, and that history, notes and settings are imported. Test both the install script and a quarantined browser download, including first launch offline. Automated signature and layout checks do not prove permission continuity.

References: [Tauri updater](https://v2.tauri.app/plugin/updater/), [Mac signing](https://v2.tauri.app/distribute/sign/macos/), [Windows signing](https://v2.tauri.app/distribute/sign/windows/).
