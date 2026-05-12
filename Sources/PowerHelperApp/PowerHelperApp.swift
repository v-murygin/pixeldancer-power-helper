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
                .frame(width: 520, height: 460)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
