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

Release builds are signed with a self-signed `Pressay Release Signing` certificate. macOS ties Microphone, Accessibility and Input Monitoring approvals to it, so updates keep their permissions as long as every release uses the same certificate. It needs no paid account. It does not make the app notarized, so Gatekeeper's first-launch warning remains.

Set it up once:

```bash
./scripts/create-release-signing-certificate.sh
```

The script stores the certificate in the repository's `RELEASE_SIGNING_CERTIFICATE` and `RELEASE_SIGNING_PASSWORD` Actions secrets, plus a backup in the login keychain. Keep that backup: replacing the certificate makes every user approve permissions again. The first release signed with it also asks once, because earlier releases were ad-hoc signed.

## Publish

1. Update `CFBundleShortVersionString` and increase `CFBundleVersion` in `Config/Info.plist`.
2. Merge the tested change, then push a matching `vX.Y.Z` tag.
3. The workflow builds the app and DMG signed with the release certificate, packages the ZIP, and uses Sparkle’s `generate_appcast` to sign the archive and generate its feed. A missing Sparkle key or release certificate fails the release.
4. GitHub publishes `Pressay-macos-arm64.zip`, `SHA256SUMS`, `appcast.xml`, and the versioned DMG. The app’s fixed `releases/latest/download/appcast.xml` URL resolves to the latest release; the feed’s download URL pins its exact release tag.

Each feed contains the current stable release. No server, Pages deployment, alternate channel, or delta update storage is needed. Do not edit or replace an archive after signing it. Publishing another release requires a higher build number.

## Verify before distributing

Install a release on a clean supported Mac or VM, then update to a release with a higher build number. Check the visible notice, download progress, restart, retained settings/notes/models, and failure recovery. Start dictation or a meeting before requesting an update and confirm that it waits. Repeat with a recording started while the download is running.

Test both Terminal and browser downloads. The app is not Apple-notarized. The Terminal installer does not disable Gatekeeper, but browser downloads can require Open Anyway. Ad-hoc code signatures can change macOS permission identity across releases; test microphone, Accessibility, Input Monitoring, and System Audio Recording after updating, and document any reapproval. Keeping a bundle identifier alone does not guarantee permission continuity.
