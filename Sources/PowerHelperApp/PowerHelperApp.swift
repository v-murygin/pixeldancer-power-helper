//
//  PowerHelperApp.swift
//  PixelDancerPowerHelper — user-facing installer/status GUI.
//
//  This is a small standalone app. Its only job: register the embedded
//  LaunchDaemon via SMAppService.daemon, show the user the current state,
//  and expose Install/Uninstall buttons. After the user enables the daemon
//  once in System Settings → Login Items, this GUI can be quit — the
//  daemon persists and serves the sandboxed main PixelDancer app via XPC.
//

import SwiftUI
import ServiceManagement
import PowerHelperShared

@main
struct PowerHelperApp: App {

    var body: some Scene {
        Window("PixelDancer Power Helper", id: "main") {
            ContentView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commands {
            // Drop File menu (single-window utility, no documents).
            CommandGroup(replacing: .newItem) { }
            // Standard Help command pointing at the GitHub repo so the
            // menu bar has at least one app-specific entry.
            CommandGroup(replacing: .help) {
                Link("PixelDancer Power Helper Help",
                     destination: URL(string: "https://github.com/v-murygin/pixeldancer-power-helper#readme")!)
            }
        }
    }
}
