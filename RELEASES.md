# Releasing Humanist

Operational notes for taking a `Scripts/run-app.sh` build and turning
it into something you can hand to another person — signed, notarized,
packaged in a DMG, hosted on GitHub Releases. Optional Sparkle
auto-updates at the end.

The Surya and Tesseract setup wizards (`SuryaSetupSheet` /
`TesseractSetupSheet`) mean we ship a small bundle (~14 MB) and let
users install the heavy dependencies themselves on first launch.
Notarization is straightforward in this configuration because there
are essentially no inner Mach-O binaries — just the Swift executable
and the bundled CodeMirror assets.

This document covers two distribution stages:

- **Pre-flight** (the section right below) — share the current build
  with a small group of testers without an Apple Developer Program
  membership. Works today; testers see one Gatekeeper warning that
  they dismiss with right-click → Open.
- **Public release** (sections 1–11) — Developer ID + notarization +
  DMG + GitHub Releases for distribution to people you can't talk to.

---

## Pre-flight: sharing builds with testers (no Developer Program required)

The fastest path to "send the app to a few people" — what's actually
appropriate while you're still iterating and only handing builds to
people you know. Skips the entire Developer Program / notarization /
DMG track.

### What testers will see

The build today is signed with your Apple Development certificate
(pinned hash in `Scripts/build-app.sh`). For another machine, this
is functionally equivalent to ad-hoc signing — Apple Development
isn't a distribution cert, so Gatekeeper treats it the same way it
treats unsigned binaries:

1. Tester downloads the .zip and unzips (Finder does this on
   double-click).
2. They drag `Humanist.app` to `/Applications` (or wherever).
3. **First double-click** triggers Gatekeeper:
   *"\"Humanist\" cannot be opened because Apple cannot check it
   for malicious software."*
4. They dismiss, then **right-click the app → Open** → click
   **Open** in the resulting confirmation alert.
5. macOS remembers the override. Subsequent launches are silent.

The right-click bypass is the only friction. Testers who can follow
"right-click → Open → Open" can run the app indefinitely.

### Build and zip the .app

```sh
# Build with the pinned Apple Development cert (the default)
Scripts/run-app.sh

# Use ditto, not zip(1) — preserves bundle structure, code-signing
# metadata, and extended attributes that plain zip mangles.
cd build
ditto -c -k --keepParent Humanist.app Humanist.zip

# Verify the zip round-trips cleanly
ditto -x -k Humanist.zip /tmp/zip-check && \
    codesign --verify --deep --strict /tmp/zip-check/Humanist.app && \
    echo "OK"
rm -rf /tmp/zip-check
```

The zip is ~14 MB. iMessage handles it inline; Drive / Dropbox /
WeTransfer / iCloud Drive all work for sharing the link. Email
attachment limits (25 MB on most providers) leave headroom but
cloud links are friendlier.

### Build and zip the CLI

If your testers want the CLI too:

```sh
swift build --product humanist-cli -c release
BIN="$(swift build --show-bin-path -c release)/humanist-cli"
codesign --force --sign - "$BIN"
ditto -c -k --keepParent "$BIN" humanist-cli.zip
```

`swift build --show-bin-path -c release` resolves the binary's
directory dynamically. `Scripts/build-app.sh` uses
`swift build -c release --arch arm64` (arch-explicit), which lands
outputs under `.build/arm64-apple-macosx/release/` rather than the
bare `.build/release/` symlink — `--show-bin-path` returns the
right directory either way. `codesign --force --sign -` is the
ad-hoc sign you want for tester distribution.

CLI binary is ~6 MB. The ad-hoc sign suppresses the
"unsigned-binary" Terminal warning on first run; testers may still
need to grant permission once via System Settings → Privacy &
Security → "Allow Anyway" if Gatekeeper escalates.

### Tester quick-start (paste into the email / DM)

````markdown
# Humanist build — first launch

1. Download `Humanist.zip`, double-click to unzip.
2. Drag **Humanist.app** to your `/Applications` folder.
3. **First launch only:** right-click the app → choose **Open** →
   click **Open** in the dialog. macOS remembers the override
   afterwards; you can double-click normally from then on.
4. Walk through the welcome sheet. Optional setup wizards for
   **Surya** (~1 GB, layout analysis) and **Tesseract** (~150 MB,
   classical-script OCR) appear if those engines aren't installed —
   skip either if you don't need them.
5. Drop a PDF onto the launcher to convert.

For the CLI (optional):

```sh
unzip humanist-cli.zip
chmod +x humanist-cli
sudo mv humanist-cli /usr/local/bin/
humanist-cli --help
```

Requires macOS 26 (Tahoe) on Apple Silicon. Bug reports / weird
output → let me know.
````

### When something goes wrong on the tester's end

Three failures show up most often. None require rebuilding.

- **"Humanist is damaged and can't be opened. You should move it to
  the Trash."** — macOS quarantined the bundle on download and
  Gatekeeper isn't letting them through. Have them run:

  ```sh
  xattr -d com.apple.quarantine /Applications/Humanist.app
  ```

  Then double-click. This bypasses the right-click dance entirely.

- **App moves itself to Trash on launch.** OCSP-revoked-cert
  symptom (per the project memory). Build with
  `HUMANIST_ADHOC_SIGN=1 Scripts/run-app.sh` and re-send — ad-hoc
  signing sidesteps the cert-validity check.

- **Setup wizard install hangs.** Surya / Tesseract / Ollama
  install commands stream output via the wizard's log pane; if
  that pane stays empty for >30 s the underlying `Process` is
  probably waiting on a sudo prompt or interactive confirmation
  that wasn't surfaced. Ask the tester to run the install command
  manually in Terminal:
  ```sh
  uv tool install surya-ocr        # Surya
  brew install tesseract tesseract-lang  # Tesseract
  ollama pull gemma4:26b           # Ollama
  ```

### When to graduate from pre-flight to a real release

Move on to sections 1–11 below when:

- You're sending builds to more than ~10 people.
- Testers without "right-click → Open" instinct start asking what
  to do.
- You want updates to install automatically (Sparkle).
- You're listing the app somewhere public.

For "second laptop, three friends, a colleague" — pre-flight is
fine indefinitely.

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

### Install (GUI)
Download `Humanist-1.0.0.dmg`, mount, drag to Applications. First
launch offers to install **Surya** (layout analysis, ~1 GB) and
**Tesseract** (classical-script OCR, ~150 MB) via in-app setup
wizards. Both are optional — without them conversions fall back to
Apple Vision OCR.

### Install (CLI)
```sh
curl -L https://github.com/USER/ocr/releases/download/v1.0.0/humanist-cli-1.0.0-arm64.tar.gz | tar xz
sudo mv humanist-cli /usr/local/bin/
humanist-cli --version
```

Or via Homebrew tap (if configured):
```sh
brew tap USER/humanist
brew install humanist-cli
```

### Requires
macOS 26 (Tahoe) or later. Apple Silicon only.

### SHA-256
- DMG: `<sha256 of the DMG>`
- CLI tarball: `<sha256 of the .tar.gz>`
```

Hash both artifacts before publishing:

```sh
shasum -a 256 dist/Humanist-1.0.0.dmg dist/humanist-cli-1.0.0-arm64.tar.gz
```

Paste both digests into the release notes so users can verify
either download.

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

## 11. Distributing the CLI

The CLI is much simpler to ship than the .app: a single ~6 MB Mach-O,
no resources to bundle, no `.app` structure, no DMG. Sections 1–5
above (Developer ID cert + `notarytool` credential setup) apply
unchanged; the differences kick in at packaging time.

### Build and sign

```sh
swift build --product humanist-cli -c release
BIN="$(swift build --show-bin-path -c release)/humanist-cli"
codesign --force \
    --options runtime \
    --timestamp \
    --sign "$HUMANIST_SIGNING_IDENTITY" \
    "$BIN"
```

`swift build --show-bin-path -c release` resolves the binary's
directory regardless of whether the most recent build was
arch-explicit (`Scripts/build-app.sh` uses `--arch arm64`, which
lands under `.build/arm64-apple-macosx/release/` rather than the
bare `.build/release/`).

No `--entitlements` flag — CLIs don't need a sandbox profile and
the entitlements file is for the `.app` bundle. The hardened-runtime
+ timestamp flags are still required for notarization.

### Notarize

`notarytool` accepts a zip; CLIs can't be submitted as a bare binary.

```sh
ditto -c -k --keepParent "$BIN" humanist-cli.zip

xcrun notarytool submit humanist-cli.zip \
    --keychain-profile humanist-notary \
    --wait
```

**Important difference from the `.app`:** you cannot `stapler staple`
a CLI binary. Stapling only works on `.app` / `.pkg` / `.dmg`
containers. For a notarized CLI, Gatekeeper verifies the
notarization online on first run instead of from an attached ticket.
This means:

- First-run requires internet access.
- Subsequent runs cache the verdict.
- Terminal-launched binaries get less Gatekeeper scrutiny than
  double-clicked apps regardless, so the notarization is mostly a
  trust signal for users who care to check rather than a hard
  blocker.

If you want a stapleable container, wrap the CLI in a `.pkg`
installer instead — `productbuild` builds one, you can `stapler
staple` it, and `pkg` installers are the convention for command-line
tools shipped through enterprise channels. For personal /
small-team distribution this is overkill; the zipped binary plus
online notarization works fine.

### Package for distribution

Tarball is the convention for CLI tools:

```sh
mkdir -p dist
cp "$BIN" dist/humanist-cli
cp Sources/HumanistCLI/README.md dist/README.md
cp LICENSE dist/ 2>/dev/null || true

VERSION="1.0.0"
TARBALL="dist/humanist-cli-${VERSION}-arm64.tar.gz"
( cd dist && tar -czf "$(basename "$TARBALL")" humanist-cli README.md LICENSE 2>/dev/null )
shasum -a 256 "$TARBALL"
```

Note the `arm64` in the filename. Humanist is Apple-Silicon only,
and the CLI binary is single-arch by default. If you ever produce
a universal binary (`swift build --arch arm64 --arch x86_64`),
rename to `universal2` to match Apple's convention.

### Distribute

Two channels are worth offering:

**GitHub Releases (simplest, always available)**

Users download the tarball directly:

```sh
gh release create v1.0.0 \
    dist/Humanist-1.0.0.dmg \
    dist/humanist-cli-1.0.0-arm64.tar.gz \
    --title "Humanist 1.0.0" \
    --notes-file release-notes.md
```

The release notes should include a one-liner install:

```sh
curl -L https://github.com/USER/ocr/releases/download/v1.0.0/humanist-cli-1.0.0-arm64.tar.gz | tar xz
sudo mv humanist-cli /usr/local/bin/
humanist-cli --version
```

**Homebrew tap (richer UX for users who already use brew)**

For users on Homebrew, a tap formula lets them
`brew install <tap>/humanist-cli`. Two-step setup:

1. Create a separate repo named `homebrew-humanist` (the
   `homebrew-` prefix is required by `brew tap`).
2. Add `Formula/humanist-cli.rb`:

```ruby
class HumanistCli < Formula
  desc "Convert academic PDFs to EPUB / Markdown / HTML / DOCX / searchable PDF"
  homepage "https://github.com/USER/ocr"
  url "https://github.com/USER/ocr/releases/download/v1.0.0/humanist-cli-1.0.0-arm64.tar.gz"
  sha256 "<paste shasum -a 256 output>"
  version "1.0.0"
  license "MIT"  # or whatever applies

  depends_on arch: :arm64
  depends_on macos: :tahoe   # macOS 26+

  # Optional dependencies — the CLI auto-detects them at runtime.
  # Listing here gives users `brew install --with-tesseract` style
  # guidance via the caveats block below.
  # depends_on "tesseract" => :optional
  # depends_on "epubcheck" => :optional

  def install
    bin.install "humanist-cli"
  end

  def caveats
    <<~EOS
      humanist-cli works out of the box with Apple Vision OCR.
      For full functionality, install the optional dependencies:
        brew install tesseract tesseract-lang   # classical-script OCR
        brew install epubcheck                  # `humanist-cli validate`
        uv tool install surya-ocr               # layout analysis
    EOS
  end

  test do
    system "#{bin}/humanist-cli", "--version"
  end
end
```

3. Users install:

```sh
brew tap USER/humanist
brew install humanist-cli
```

Per release: bump `url` + `sha256` + `version` in the formula and
push to the tap repo. Brew handles upgrade detection automatically.

### Send-to-a-friend path (no Developer ID required)

For one-off sharing — a colleague, a CI machine you control, your
own second laptop — ad-hoc signing works fine:

```sh
swift build --product humanist-cli -c release
codesign --force --sign - .build/release/humanist-cli
ditto -c -k --keepParent .build/release/humanist-cli humanist-cli.zip
```

Recipient unzips, runs from Terminal. macOS may prompt once on
first run; once approved, it runs without warnings. No
notarization required because Terminal-launched binaries are not
double-clicked apps and Gatekeeper applies a softer policy.

This is the "share with a small group of testers" path mirrored
from the `.app` story above. Identical trade-off: works fine for
people you can talk to, not the right path for public
distribution.

### Per-release CLI checklist

- [ ] `swift build --product humanist-cli -c release` succeeds.
- [ ] `codesign --verify` passes against `Developer ID Application`.
- [ ] `notarytool submit` returns `Accepted`.
- [ ] Tarball assembled with binary + README + LICENSE.
- [ ] SHA-256 computed and recorded.
- [ ] If using a Homebrew tap: formula updated with new url +
      sha256 + version, pushed to the tap repo.
- [ ] Smoke test on a clean Mac:
      `curl -L <release-url> | tar xz && ./humanist-cli convert sample.pdf -f md`

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
- [ ] `swift build --product humanist-cli -c release` and sign the
      CLI binary with the same Developer ID.
- [ ] Notarize the CLI zip via `notarytool submit`.
- [ ] Tarball the CLI (`humanist-cli`, `README.md`, `LICENSE`) per
      §11.
- [ ] Compute and record SHA-256 for both the DMG and the CLI tarball.
- [ ] `git tag` and push.
- [ ] `gh release create` with both the DMG and the CLI tarball
      attached, plus release notes that include both install
      one-liners.
- [ ] If using a Homebrew tap: bump the `humanist-cli` formula's
      `url` + `sha256` + `version`.
- [ ] Smoke test on a clean Mac: install the .app from the DMG,
      install the CLI from `curl | tar xz` (or `brew install`).
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
