# PixelDancer Power Helper

Free companion app for **[PixelDancer](https://murygin.app/apps/pixeldancer/)**
that enables closed-lid sleep prevention — keeping a MacBook awake with the
lid closed, even on battery and with no external display.

## Why a separate app?

PixelDancer is distributed through the Mac App Store and runs in a sandbox.
Apple's sandbox prevents the app from invoking `pmset disablesleep`, the only
mechanism that reliably overrides macOS's closed-lid sleep on Apple Silicon.

This helper is distributed outside the App Store (Developer ID notarized) so
it can install a small privileged background service (a launchd daemon)
running as root. When PixelDancer's Agent Mode starts, it asks the daemon
over an XPC connection to flip the pmset flag. When the session ends, the
daemon flips it back.

Same architecture as Amphetamine + Amphetamine Enhancer, Macchiato, and
AlDente Pro.

## Download

Latest signed and notarized DMG: see the **[Releases](../../releases)** page.

After installing, return to PixelDancer — Agent Mode picks up the helper
automatically and the "Power Helper installed" green banner appears in
Settings.

## What the daemon actually does

Two operations, hardcoded, nothing else:

```
/usr/bin/pmset -a disablesleep 1   # when Agent Mode starts
/usr/bin/pmset -a disablesleep 0   # when Agent Mode ends
```

No network access. No file system writes outside the macOS log directory.
No telemetry. Only PixelDancer can talk to it (Mach service, sandboxed
caller).

## Project layout

```
.
├── Package.swift                            — Swift Package definition
├── Shared/
│   └── PowerHelperProtocol.swift            — XPC interface
├── Sources/
│   ├── PowerHelperApp/                      — User-facing installer GUI (SwiftUI)
│   │   ├── PowerHelperApp.swift
│   │   └── ContentView.swift
│   └── PowerHelperDaemon/                   — Privileged background service
│       └── main.swift
├── Bundle/
│   ├── Info.plist                           — App bundle metadata
│   └── LaunchDaemons/
│       └── com.vm.PixelDancerPowerHelper.daemon.plist
├── Entitlements/
│   ├── app.entitlements                     — Hardened Runtime, no sandbox
│   └── daemon.entitlements                  — Hardened Runtime, no sandbox
└── build.sh                                  — Compile + assemble .app bundle
```

## Open in Xcode (for editing UI / translations)

```bash
open Package.swift
```

Xcode opens the package, indexes both targets, lets you edit SwiftUI views
and add resources. To build/run from Xcode pick the `PixelDancerPowerHelper`
scheme and hit ⌘R.

### Adding translations

UI strings live in
[`Sources/PowerHelperApp/Resources/Localizable.xcstrings`](Sources/PowerHelperApp/Resources/Localizable.xcstrings).
Open it in Xcode — the Strings Catalog editor lets you add languages and fill
in translations side by side. The English source strings (used in SwiftUI
`Text`, `Button`, `Label`) are extracted automatically when Xcode builds.

SwiftPM's resources system processes the catalog and SwiftUI looks it up via
`Bundle.module` at runtime — no extra wiring.

## Build from source

```bash
./build.sh
```

Produces an unsigned `build/PixelDancer Power Helper.app`. For redistribution
you need to sign with a Developer ID Application certificate and notarize
through Apple — see *Sign + Notarize* below.

## Releasing (maintainers)

Releases are fully automated via [`.github/workflows/release.yml`](.github/workflows/release.yml).
To cut a release:

```bash
# 1. Bump CFBundleShortVersionString + CFBundleVersion in Bundle/Info.plist
# 2. Commit and push
git commit -am "chore: bump to v1.0.X"
git push

# 3. Tag and push the tag — this triggers CI
git tag -a v1.0.X -m "v1.0.X"
git push origin v1.0.X
```

CI then:

1. Verifies the tag version matches `Info.plist`
2. Builds, signs daemon + app, notarizes, staples
3. Builds DMG, signs, notarizes, staples
4. Runs `spctl --assess` for Gatekeeper sanity
5. Publishes a GitHub Release with the DMG attached and auto-generated notes

PixelDancer's in-app installer pulls
`https://github.com/v-murygin/pixeldancer-power-helper/releases/latest/download/PixelDancerPowerHelper.dmg`
— the workflow always uploads the asset with that exact filename.

### Required secrets (one-time setup)

`Settings → Secrets and variables → Actions` on GitHub:

| Secret | What it is |
|---|---|
| `DEVELOPER_ID_CERT_P12` | base64 of `.p12` export of the "Developer ID Application" cert + private key |
| `DEVELOPER_ID_CERT_PASSWORD` | password used during the `.p12` export |
| `APPLE_ID` | Apple ID email used for notarization |
| `APPLE_TEAM_ID` | 10-character team ID (`S5W3985ZD8`) |
| `APPLE_APP_PASSWORD` | app-specific password from [appleid.apple.com](https://appleid.apple.com) |

#### Exporting the cert

1. **Keychain Access** → *My Certificates* → right-click *Developer ID
   Application: Vladislav Murygin (S5W3985ZD8)* → **Export** → save as
   `dev-id.p12` with a strong password.
2. base64-encode for the secret:
   ```bash
   base64 -i dev-id.p12 | pbcopy
   ```
3. Paste the result into the `DEVELOPER_ID_CERT_P12` secret on GitHub.
4. Paste the export password into `DEVELOPER_ID_CERT_PASSWORD`.
5. Delete the local `dev-id.p12` once both secrets are saved.

The `gh` CLI can set them in one go:

```bash
gh secret set DEVELOPER_ID_CERT_P12 < <(base64 -i dev-id.p12)
gh secret set DEVELOPER_ID_CERT_PASSWORD     # prompts for the value
gh secret set APPLE_ID --body "vl.murygin@gmail.com"
gh secret set APPLE_TEAM_ID --body "S5W3985ZD8"
gh secret set APPLE_APP_PASSWORD             # prompts for the value
```

### Manual fallback (for emergencies)

If CI is broken and you need to cut a release locally, the same flow runs
by hand. See git history for the previous manual workflow text, or just
read the steps inside `release.yml` — it's a literal translation.

## XPC contract

`PowerHelperProtocol` (in `Shared/PowerHelperProtocol.swift`):

| Method                          | Purpose                                       |
| ------------------------------- | --------------------------------------------- |
| `ping(reply:)`                  | Heartbeat. Returns protocol version + name    |
| `enableSleepOverride(reply:)`   | `pmset -a disablesleep 1`                     |
| `disableSleepOverride(reply:)`  | `pmset -a disablesleep 0`                     |
| `currentStatus(reply:)`         | Reads `pmset -g`, returns enabled flag + raw  |

Mach service: `com.vm.PixelDancerPowerHelper.daemon`

## Install flow (end-user)

1. Download the DMG from Releases (or use PixelDancer's in-app installer)
2. Drag *PixelDancer Power Helper.app* to Applications
3. Launch the helper once → click **Install**
4. macOS opens System Settings → Login Items & Extensions → toggle the
   daemon on (may ask for admin password)
5. Close the helper — daemon stays in the background
6. Open PixelDancer; Agent Mode now keeps the Mac awake with the lid closed

## License

[MIT](LICENSE).
