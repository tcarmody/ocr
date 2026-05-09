# Releasing Humanist

Operational notes for taking a `Scripts/run-app.sh` build and turning
it into something you can hand to another person — signed, notarized,
packaged in a DMG, hosted on GitHub Releases. Optional Sparkle
auto-updates at the end.

The Surya and Tesseract setup wizards (`SuryaSetupSheet` /
`TesseractSetupSheet`) mean we ship a small bundle (~15 MB) and let
users install the heavy dependencies themselves on first launch.
Notarization is straightforward in this configuration because there
are essentially no inner Mach-O binaries — just the Swift executable
and the bundled CodeMirror assets.

---

## Prerequisites

- **Apple Developer Program membership** (\$99/year). Without this you
  cannot get a Developer ID Application certificate, and without that
  certificate you cannot notarize. Ad-hoc signing is fine for testing
  but Gatekeeper will warn on every first-launch on every machine that
  hasn't seen the app before.
- **Xcode + command-line tools.** `notarytool`, `stapler`, `codesign`,
  `hdiutil`, and `productbuild` all ship with Xcode.
- **An app-specific password for your Apple ID.** Generate at
  appleid.apple.com → Sign-In and Security → App-Specific Passwords.
  Store it once via `xcrun notarytool store-credentials` (see step 4).
- **GitHub CLI (`gh`)** if you're using GitHub Releases for hosting.

---

## 1. Get the Developer ID certificate

In Xcode → Settings → Accounts → your Apple ID → Manage Certificates →
`+` → "Developer ID Application". Xcode generates the cert and
private key in your login keychain.

Verify it's there:

```sh
security find-identity -v -p codesigning
```

You should see something like:

```
1) ABCDEF1234567890... "Developer ID Application: Your Name (TEAMID)"
```

Copy the full identity string (`Developer ID Application: ...`). You'll
paste this into `build-app.sh` next.

The `TEAMID` in parentheses is your 10-character Team ID. Note it down
separately — you'll need it for notarization.

---

## 2. Update `Scripts/build-app.sh` to use the Developer ID cert

The script currently uses ad-hoc signing (`codesign -s -`). Change it
to use your Developer ID identity, with the hardened-runtime flag that
notarization requires.

Find the `codesign` call in `Scripts/build-app.sh` and replace it with
something like:

```sh
SIGNING_IDENTITY="${HUMANIST_SIGNING_IDENTITY:-Developer ID Application: Your Name (TEAMID)}"

codesign --force --deep \
    --options runtime \
    --timestamp \
    --sign "$SIGNING_IDENTITY" \
    "$APP_BUNDLE"
```

Key flags:
- `--options runtime` — enables the **hardened runtime**. Required for
  notarization. Without it, notarization rejects the submission.
- `--timestamp` — embeds an Apple timestamp signature. Required for
  notarization.
- `--deep` — recursively signs nested bundles. Belt-and-suspenders
  here since we don't have nested bundles, but harmless.

The `HUMANIST_SIGNING_IDENTITY` env var lets you keep the script
generic; pass the identity at build time:

```sh
HUMANIST_SIGNING_IDENTITY="Developer ID Application: ..." Scripts/build-app.sh
```

Verify the signature is real (not ad-hoc):

```sh
codesign -dvv build/Humanist.app 2>&1 | grep -E "Authority|TeamIdentifier"
```

Should show your name as the authority and your TEAMID. Ad-hoc would
show `Authority=(unknown)`.

### Entitlements

`BundleAssets/Humanist.entitlements` is already in place. Open it and
verify it contains the entitlements your app actually uses. For
Humanist that means:

```xml
<key>com.apple.security.network.client</key>      <!-- Anthropic API -->
<true/>
<key>com.apple.security.files.user-selected.read-write</key>  <!-- file picker -->
<true/>
```

App Sandbox is currently *off*. That's intentional: the editor needs
to spawn `Process` for `uv` and `brew` from the setup wizards, write
to `~/Library/Application Support`, and read PDFs from anywhere on
disk. Sandboxing all of that is a meaningful project on its own and
not required for non-App-Store distribution.

Don't add `com.apple.security.cs.allow-unsigned-executable-memory` or
`com.apple.security.cs.disable-library-validation` unless you actually
need them. Both raise notarization-review flags.

---

## 3. Test the signed build locally before submitting

```sh
HUMANIST_SIGNING_IDENTITY="..." Scripts/build-app.sh
codesign --verify --strict --verbose=2 build/Humanist.app
spctl --assess --type execute --verbose=4 build/Humanist.app
```

`spctl` will say "rejected" because the app isn't notarized yet — but
the Authority line should show your real Developer ID. If it shows
"unknown" something is wrong with the signing step.

Launch the app once locally to confirm the hardened runtime didn't
break anything. The two areas most likely to surface issues:
- The `Process` spawns in the setup wizards (`uv`, `brew`). Hardened
  runtime restricts dyld injection but doesn't restrict spawning;
  these should be fine.
- The Surya sidecar bridge (when Surya is later installed). Same
  story — `Process` is allowed.

---

## 4. Set up notarization credentials (one time)

Generate an app-specific password at
[appleid.apple.com](https://appleid.apple.com) → Sign-In and Security
→ App-Specific Passwords. Don't reuse your Apple ID password.

Store the credential in the keychain so you don't have to pass it on
every submission:

```sh
xcrun notarytool store-credentials "humanist-notary" \
    --apple-id "your@apple.id" \
    --team-id "TEAMID" \
    --password "xxxx-xxxx-xxxx-xxxx"   # the app-specific password
```

`humanist-notary` is the profile name you'll reference in subsequent
`notarytool` calls.

---

## 5. Notarize

`notarytool` accepts a directory, a zip, a DMG, or a pkg. The
simplest path is to zip the .app, submit, and re-build the DMG after
stapling.

```sh
ditto -c -k --keepParent build/Humanist.app build/Humanist.zip

xcrun notarytool submit build/Humanist.zip \
    --keychain-profile "humanist-notary" \
    --wait
```

`--wait` blocks until Apple finishes scanning (typically 1–5 minutes
for a small app). You'll get one of:

- **`Accepted`** — proceed to staple.
- **`Invalid`** — fetch the log:
  ```sh
  xcrun notarytool log <submission-id> --keychain-profile humanist-notary
  ```
  The most common rejections at this stage:
  - missing hardened-runtime flag → re-sign with `--options runtime`
  - missing secure timestamp → re-sign with `--timestamp`
  - unsigned binary inside the bundle → grep for it; should not happen
    with the wizard-based approach but check `Resources/codemirror/`
    just in case
  - unauthorized entitlement → review `Humanist.entitlements`

After acceptance:

```sh
xcrun stapler staple build/Humanist.app
xcrun stapler validate build/Humanist.app
```

Stapling embeds the notarization ticket so Gatekeeper accepts the
app even if the user's machine is offline on first launch. Without
stapling, Gatekeeper has to phone Apple to verify — works but adds
a delay and fails offline.

Verify the final state:

```sh
spctl --assess --type execute --verbose=4 build/Humanist.app
```

Should now print `accepted ... source=Notarized Developer ID`.

---

## 6. Build a DMG

Create `Scripts/build-dmg.sh`:

```sh
#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:?usage: build-dmg.sh <version>}"
APP="build/Humanist.app"
DMG="dist/Humanist-${VERSION}.dmg"

mkdir -p dist
rm -f "$DMG"

# Stage a folder with the app + a /Applications symlink. hdiutil will
# package this as a read-only DMG.
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create \
    -volname "Humanist ${VERSION}" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DMG"

rm -rf "$STAGE"

# DMGs need to be signed too; the notarization ticket attached to the
# .app inside doesn't carry over to the wrapper.
codesign --force --sign "${HUMANIST_SIGNING_IDENTITY}" --timestamp "$DMG"

# And the DMG itself wants its own notarization pass.
xcrun notarytool submit "$DMG" --keychain-profile humanist-notary --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "Built and notarized: $DMG"
```

Make it executable:

```sh
chmod +x Scripts/build-dmg.sh
```

Run after the .app is built and stapled:

```sh
Scripts/build-dmg.sh 1.0.0
```

Result: `dist/Humanist-1.0.0.dmg`, signed and notarized, ready to
distribute.

### DMG niceties (optional)

For a polished experience, drop a background image at
`BundleAssets/dmg-background.png` and configure the DMG layout via
AppleScript or a tool like `create-dmg`. Not required for a working
release; the bare DMG with the `/Applications` symlink already gives
the standard "drag to install" UX.

---

## 7. Host on GitHub Releases

```sh
# Tag the commit
git tag -a v1.0.0 -m "Humanist 1.0.0"
git push origin v1.0.0

# Create the release with the DMG attached
gh release create v1.0.0 dist/Humanist-1.0.0.dmg \
    --title "Humanist 1.0.0" \
    --notes-file release-notes.md
```

`release-notes.md` template (per release):

```markdown
## Humanist 1.0.0

### Highlights
- (1–3 user-visible bullets)

### Setup
First launch will offer to install **Surya** (layout analysis,
~1 GB) and **Tesseract** (classical-script OCR, ~150 MB) via their
respective setup wizards. Both are optional — without them
conversions fall back to Apple Vision.

### Requires
macOS 26 (Tahoe) or later. Apple Silicon recommended; Intel Macs
work but have not been tested in this release.

### SHA-256
`<sha256 of the DMG>`
```

Hash the DMG before publishing:

```sh
shasum -a 256 dist/Humanist-1.0.0.dmg
```

Paste the digest into the release notes so users can verify their
download.

---

## 8. Documentation updates per release

For each release, before tagging:

- **`README.md`** — bump version mentions; verify the install
  instructions still match the current setup-wizard flow.
- **`PLANS.md`** — move shipped items out of the "Next" sections.
- **`CHANGELOG.md`** (create if missing) — running list of versions
  with their highlights.
- **In-app Welcome sheet** — does the screenshot or section list
  reflect the new release? Edit `WelcomeSheet.swift` if not.

---

## 9. Smoke-test on a clean Mac before announcing

This is the step that catches everything you assumed about your dev
machine. Find a Mac that has never run Humanist (a borrowed one, a
fresh user account, a VM):

1. Download the DMG from the GitHub Releases URL (not from local
   disk — verifies the upload worked).
2. Verify the digest matches the release notes:
   `shasum -a 256 ~/Downloads/Humanist-1.0.0.dmg`
3. Mount, drag to Applications, eject DMG.
4. Launch from Applications. Confirm Gatekeeper shows no warning
   (notarization is working).
5. Walk through the Welcome sheet end-to-end.
6. Run the Surya setup wizard. Verify `uv` install instructions are
   accurate, then run the install. Quit and reopen.
7. Run the Tesseract setup wizard. Verify Homebrew install
   instructions, then install.
8. Convert one PDF — a known-good test case from your library.
9. Open the resulting EPUB in the editor; verify the source pane,
   preview pane, and WYSIWYG pane all render.
10. (If Cloud-mode applies) Set the Anthropic API key in Settings,
    verify a single Claude page-OCR conversion lands.

If any step fails, the release is not ready. Fix and re-run.

---

## 10. (Optional) Sparkle for auto-updates

Skip this on the first release. Add later when you have multiple
releases that warrant getting users onto the latest version
automatically.

When you do add it:

1. **Vendor Sparkle 2.x** as a Swift Package dependency:
   ```swift
   .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
   ```
   Add `Sparkle` to the `Humanist` target dependencies.

2. **Generate an EdDSA key pair** for signing updates. Sparkle
   ships a `generate_keys` tool:
   ```sh
   ./bin/generate_keys
   ```
   Stores the private key in your keychain, prints the public key.
   Add the public key to `Info.plist` as `SUPublicEDKey`.

3. **Add the feed URL** to `Info.plist` as `SUFeedURL`. Point it at a
   GitHub Pages-hosted `appcast.xml` (`https://<user>.github.io/<repo>/appcast.xml`).

4. **Initialize the updater** in `HumanistApp.init()`:
   ```swift
   let updater = SPUStandardUpdaterController(
       startingUpdater: true,
       updaterDelegate: nil,
       userDriverDelegate: nil
   )
   ```
   Plus a "Check for Updates…" menu item in the Help menu.

5. **Per release**, sign the DMG and update the appcast:
   ```sh
   ./bin/sign_update dist/Humanist-X.Y.Z.dmg
   ```
   Outputs a Sparkle signature; paste into the new `<item>` in
   `appcast.xml` along with the version, length, and download URL.
   Push `appcast.xml` to the `gh-pages` branch.

The Sparkle docs at sparkle-project.org are thorough and worth
following directly when you actually wire this up — easier than my
secondhand summary.

---

## Summary checklist for shipping a release

For each version, in order:

- [ ] All commits intended for the release are on `main`.
- [ ] `PLANS.md` and `README.md` reflect the current state.
- [ ] Bump version number wherever it lives (`Info.plist`,
      `Scripts/build-app.sh`, etc.).
- [ ] `HUMANIST_SIGNING_IDENTITY="..." Scripts/build-app.sh`
- [ ] Local `codesign --verify` and `spctl --assess` pass with the
      Developer ID identity.
- [ ] Notarize the .app: `notarytool submit ... --wait` returns
      `Accepted`.
- [ ] `stapler staple` the .app.
- [ ] `Scripts/build-dmg.sh <version>` (signs + notarizes + staples
      the DMG).
- [ ] Compute and record the SHA-256.
- [ ] `git tag` and push.
- [ ] `gh release create` with the DMG and notes.
- [ ] Smoke test on a clean Mac via the GitHub Releases URL.
- [ ] Announce.

---

## Things this document deliberately doesn't cover

- **App Store distribution.** Sandboxing every Process spawn is a
  major refactor and the bundle size (with Surya) is far over the
  App Store soft cap. Direct DMG distribution is the right model.
- **Cross-architecture builds.** Apple Silicon is the only
  supported target; Intel is best-effort. If demand surfaces,
  add `--arch x86_64 --arch arm64` to the swift build invocation
  in `build-app.sh`.
- **CI.** GitHub Actions can do every step here unattended, but the
  Developer ID cert + notary credentials need to live in encrypted
  secrets and the configuration is fiddly. Worth the effort once
  releases happen often enough to be a recurring tax.
