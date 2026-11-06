# Releases and updates

Pressay uses GitHub Releases for downloads and Sparkle for signed, user-initiated installation. Automatic checks are on by default; automatic installation and system profiling are off. The update notice stays inside the app. An installation request waits for dictation, processing, and meeting recording to finish.

After updating, the main window reopens if it was visible before restarting. An update requested from the menu bar keeps the app in the background if its main window was closed.

## Signing key

`Config/Info.plist` contains the public `SUPublicEDKey`. The matching private key belongs in the repository’s `SPARKLE_PRIVATE_KEY` Actions secret. It is separate from Apple code signing and requires no paid account. Never commit or print it.

For the initial setup, use the `generate_keys` tool from the pinned Sparkle release:

```bash
generate_keys --account dev.localflow.app
```

The tool stores the private key in the login keychain and prints the public key. Set the printed public key in `Config/Info.plist` before distributing the first updatable app. Export the private key to a temporary file with `generate_keys --account dev.localflow.app -x <file>`, then pass that file on stdin to `gh secret set SPARKLE_PRIVATE_KEY --repo Zheruel/pressay-macos`. Remove the temporary file and keep a secure backup of the key. Keep the same key for subsequent releases; replacing it without a supported key rotation strands existing installs.

## App signing certificate

The existing public release path uses the stable, self-signed **Pressay Release Signing** certificate. It remains available without Apple membership and is explicitly labeled unnotarized in release notes. Set it up with `scripts/create-release-signing-certificate.sh`; it stores the certificate in `RELEASE_SIGNING_CERTIFICATE` and its password in `RELEASE_SIGNING_PASSWORD`. Keep the certificate backed up: replacing the identity may require users to approve permissions again.

For trusted public releases, configure a **Developer ID Application** certificate and notarization, then set the repository variable `PRESSAY_NOTARIZE` to `1`. This mode requires hardened runtime, notarization, and stapled tickets; it cannot silently fall back to self-signing. Leave the variable unset or `0` until credentials are ready. Local builds also remain available: `scripts/build-app.sh` uses an available identity or ad-hoc signing, and `scripts/package-dmg.sh` notarizes only when explicitly requested.

Export the Developer ID certificate and its private key from Keychain Access as a password-protected `.p12`. Store its base64 contents in `RELEASE_SIGNING_CERTIFICATE` and its password in `RELEASE_SIGNING_PASSWORD`. Use the same Apple developer team and `dev.localflow.app` bundle identifier for future releases. Keep the certificate and Sparkle key backed up securely.

Moving from self-signing to Developer ID changes the signing identity: existing users may need to approve permissions again. Keeping the bundle identifier alone does not preserve TCC permissions. The self-signed certificate is accepted only when notarization is disabled.

## Notarization credentials

Configure these Actions secrets from an App Store Connect API key authorized for notarization:

| Secret | Contents |
| --- | --- |
| `APPLE_NOTARY_KEY` | The `.p8` private key text |
| `APPLE_NOTARY_KEY_ID` | The API key identifier |
| `APPLE_NOTARY_ISSUER` | The API issuer identifier |

With `PRESSAY_NOTARIZE=1`, the workflow imports credentials into a temporary keychain, removes the temporary `.p8` file immediately, and deletes the keychain even when a release fails. Packaging submits and staples the app first, then creates and notarizes the DMG. Sparkle packages the already stapled app. Rejected or timed-out submissions, missing tickets, invalid nested signatures, and failed Gatekeeper assessments stop publication.

For a local notarized build, save credentials interactively with `notarytool`, then provide only the profile name:

```bash
xcrun notarytool store-credentials pressay
SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
  PRESSAY_NOTARIZE=1 PRESSAY_NOTARY_PROFILE=pressay ./scripts/package-dmg.sh
```

Set `PRESSAY_NOTARY_KEYCHAIN` as well if the profile is in a non-default keychain. The scripts never disable Gatekeeper or change user permission grants.

## Installer artwork and layout

The installer opens a 660 × 400 pt content area with 128 pt app and Applications icons at `(170, 178)` and `(490, 178)`. `packaging/macos/dmg/render-background.m` draws original Pressay artwork into a TIFF containing 1× and 2× representations. Finder draws the real, draggable icons over it; the illustration is not a substitute for installing the app.

Packaging requires Python 3 and creates an isolated `.build/dmg-tools` environment with pinned `dmgbuild`, `ds_store`, and `mac_alias` versions. It does not require Finder automation, browser rendering, or a signed-in graphical session. Every generated DMG is mounted read-only to check the Applications link, background, saved icon positions, and nested app signature, then detached. Repackage an existing app for layout checks with `PRESSAY_SKIP_BUILD=1 ./scripts/package-dmg.sh`.

## Publish

1. Update `CFBundleShortVersionString` and increase `CFBundleVersion` in `Config/Info.plist`.
2. Merge the tested change, then push a matching `vX.Y.Z` tag.
3. The workflow builds and signs the app, packages and verifies the DMG, then packages the ZIP and uses Sparkle’s `generate_appcast` to sign the archive and generate its feed. Missing Sparkle or release-certificate secrets fail publication. When `PRESSAY_NOTARIZE=1`, it also notarizes, staples, and assesses both app and DMG; missing Developer ID/notarization credentials or a rejected submission fail publication.
4. GitHub publishes `Pressay-macos-arm64.zip`, `SHA256SUMS`, `appcast.xml`, and the versioned DMG. The app’s fixed `releases/latest/download/appcast.xml` URL resolves to the latest release; the feed’s download URL pins its exact release tag.

Each feed contains the current stable release. No server, Pages deployment, alternate channel, or delta update storage is needed. Do not edit or replace an archive after signing it. Publishing another release requires a higher build number.

## Verify before distributing

Install a release on a clean supported Mac or VM, then update to a release with a higher build number. Check the visible notice, download progress, restart, retained settings/notes/models, and failure recovery. Start dictation or a meeting before requesting an update and confirm that it waits. Repeat with a recording started while the download is running.

Test both Terminal and quarantined browser downloads, including first launch while offline after download. Notarized public artifacts carry stapled tickets; local ad-hoc or self-signed builds do not. Test microphone, Accessibility, Input Monitoring, and System Audio Recording after updating, including deny/revoke/regrant. Check settings, notes, vocabulary, and model preservation, and document any identity-transition reapproval. Clean-machine and update tests still require a real supported Mac; automated signature and layout checks do not prove permission continuity.

## Cross-platform desktop releases

The Rust/Tauri app has its own **Signed desktop release** workflow (`desktop-release.yml`). It does not replace the stable Swift workflow or its self-signed release option. Local installers still build with `python3 scripts/build-desktop.py`; no updater, Apple, or Microsoft credentials are required for development builds.

The optional release workflow builds macOS 26+ Apple Silicon, Windows x64, and Ubuntu 24.04+ x64. Its default is **build and upload Actions artifacts only**. `publish: true` attaches the verified desktop assets to the explicitly selected **existing published versioned GitHub release**, without overwriting native Swift assets. Download and inspect the artifacts before publishing. The public signing path fails closed if a credential, trusted signature, notarization ticket, platform artifact, or updater key is missing.

On macOS, `python3 scripts/build-desktop.py` builds the app first, signs its nested code and resource seal with an ad-hoc identity, verifies the complete bundle, then creates the branded DMG. Set `APPLE_SIGNING_IDENTITY` explicitly to use Developer ID; notarization remains opt-in through `PRESSAY_NOTARIZE=1` and `PRESSAY_NOTARY_PROFILE`. The local installer is integrity-checked but is not a trusted public release.

The desktop bundle remains `dev.localflow.preview` / **Pressay Preview** during migration, keeping its installation separate from the stable app. Cargo workspace, Tauri config, and desktop package versions must agree. The GitHub destination tag can differ from the desktop version, allowing both applications to share a release without misrepresenting either version.

### Desktop updater signing

Tauri update signatures are separate from Sparkle, Developer ID and Authenticode. Generate and back up a dedicated Tauri key using the pinned CLI:

```sh
cd apps/desktop
npm ci
npx tauri signer generate --write-keys /secure/path/pressay-desktop.key
```

Store the private file's contents in `TAURI_SIGNING_PRIVATE_KEY`, its password in `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`, and the public `.pub` contents in the repository variable `PRESSAY_UPDATE_PUBLIC_KEY`. Do not commit either private keys or passwords. The public value is compiled into the desktop binary and included in its release configuration. Replacing this key without a migration prevents existing installations from accepting future updates.

The workflow signs a temporary probe before building and verifies it against the configured public key. Final artifacts are signed **after** OS signing and Mac stapling. Each `.sig` includes the app version in its signed trusted comment; release builds require that version to match the feed. A separate job verifies both Minisign signatures with libsodium/PyNaCl, rejects mismatched versions or missing platforms, and creates `desktop-latest.json` and `DESKTOP-SHA256SUMS`.

The feed serves a notarized Mac `.app.tar.gz`, signed Windows NSIS installer, and signed Linux AppImage and Debian package. Package-specific target entries keep Debian users on Debian updates. The branded Mac DMG also receives a detached signature for manual verification.

The permanent desktop endpoint is `https://github.com/Zheruel/pressay-macos/releases/download/desktop-updates/desktop-latest.json`. The publish job creates that feed release with `--latest=false` only if it is missing, then replaces only its verified feed. Installer URLs remain on the selected immutable versioned release. Native Swift releases keep their existing “latest” behavior and cannot remove the desktop feed. Publishing a desktop update never changes which release GitHub marks latest.

### Public macOS desktop signing

Configure these additional secrets; this does not change the stable workflow's signing certificate:

| Secret | Value |
| --- | --- |
| `DESKTOP_APPLE_CERTIFICATE` | Base64 Developer ID Application `.p12`, including its private key |
| `DESKTOP_APPLE_CERTIFICATE_PASSWORD` | Password for that `.p12` |
| `APPLE_NOTARY_KEY` | App Store Connect API `.p8` contents |
| `APPLE_NOTARY_KEY_ID` | API key ID |
| `APPLE_NOTARY_ISSUER` | API issuer ID |

A temporary keychain is removed even if a build fails. Packaging signs every nested Mach-O worker/library before sealing the app, uses hardened runtime, notarizes and staples the app, builds the existing original 1×/2× Pressay DMG artwork with the actual bundle name, and notarizes/staples that DMG. The updater archive is created from the already-stapled app. Developer ID builds do not disable library validation; native libraries use the same signing identity. Native dictation, analysis, Swift MLX and meeting workers are included.

Desktop builds set the native CMake deployment target to the app’s declared macOS minimum. Before staging and public signing, `scripts/verify-macos-deployment.py` checks every Mach-O load command and rejects a helper or library requiring a newer OS. A newer SDK alone is allowed; running the installer on the oldest supported macOS remains a release acceptance check.

The DMG helper also accepts `PRESSAY_DMG_APP`, `PRESSAY_DMG_VERSION`, and `PRESSAY_DMG_OUTPUT` with `PRESSAY_SKIP_BUILD=1`. Its mounted-image verifier checks the signed bundle, actual Applications symlink, both artwork resolutions and saved Finder icon positions.

### Public Windows desktop signing

The workflow uses Microsoft's [Artifact Signing action](https://github.com/Azure/artifact-signing-action) with OIDC. This requires an external Azure subscription, completed identity validation, a **public-trust** certificate profile, and an application/federated identity granted the **Artifact Signing Certificate Profile Signer** role. Configure the federation for this repository and the workflow's intended branch/ref. No signing private key is exported to GitHub.

Set these repository variables: `PRESSAY_AZURE_CLIENT_ID`, `PRESSAY_AZURE_TENANT_ID`, `PRESSAY_AZURE_SUBSCRIPTION_ID`, `PRESSAY_AZURE_SIGNING_ENDPOINT`, `PRESSAY_AZURE_SIGNING_ACCOUNT`, and `PRESSAY_AZURE_CERTIFICATE_PROFILE`. The endpoint must match the signing account's region. The pinned official action installs ArtifactSigning PowerShell module 0.1.8 and signs the native workers/libraries; Tauri's signing hook signs its main executable, NSIS uninstaller and installer with the same service. Packaging rejects untrusted or untimestamped signatures before generating updater signatures. A valid signature does not guarantee that Windows SmartScreen has already established reputation for a new application.

Reference contracts: [Tauri updater](https://v2.tauri.app/plugin/updater/), [Mac signing](https://v2.tauri.app/distribute/sign/macos/), [Windows signing](https://v2.tauri.app/distribute/sign/windows/). These release credentials were not exercised during local development; the release workflow must be run and the downloaded installers tested on each desktop before calling the distribution path production-verified.
