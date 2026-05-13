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

## Sign + Notarize (for maintainers)

```bash
# 1. Sign the daemon executable first (inner)
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: <NAME> (<TEAM_ID>)" \
  --entitlements Entitlements/daemon.entitlements \
  "build/PixelDancer Power Helper.app/Contents/MacOS/PixelDancerPowerHelperDaemon"

# 2. Sign the GUI app (outer)
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: <NAME> (<TEAM_ID>)" \
  --entitlements Entitlements/app.entitlements \
  "build/PixelDancer Power Helper.app"

# 3. Verify
codesign -dv --verbose=4 "build/PixelDancer Power Helper.app"

# 4. Zip + notarize
ditto -c -k --keepParent "build/PixelDancer Power Helper.app" "build/PowerHelper.zip"
xcrun notarytool submit "build/PowerHelper.zip" \
  --apple-id "<APPLE_ID>" --team-id "<TEAM_ID>" \
  --password "<APP_SPECIFIC_PASSWORD>" --wait

# 5. Staple
xcrun stapler staple "build/PixelDancer Power Helper.app"

# 6. Build DMG
hdiutil create -volname "PixelDancer Power Helper" \
  -srcfolder "build/PixelDancer Power Helper.app" \
  -ov -format UDZO "build/PixelDancerPowerHelper-1.0.0.dmg"
```

Then upload the DMG as a Release asset. PixelDancer's in-app installer
fetches `https://github.com/v-murygin/pixeldancer-power-helper/releases/latest/download/PixelDancerPowerHelper.dmg`
— filename must match exactly.

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
