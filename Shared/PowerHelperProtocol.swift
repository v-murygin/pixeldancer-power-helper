//
//  PowerHelperProtocol.swift
//  PixelDancer Power Helper — shared XPC contract
//
//  Imported by BOTH the sandboxed main app (PixelDancer.app) and the
//  privileged LaunchDaemon (PixelDancerPowerHelperDaemon). Both sides need
//  the protocol so the proxy objects type-check.
//

import Foundation

/// Stable Mach service name the daemon registers on launch. The main app
/// uses this name when constructing the NSXPCConnection. Must match the
/// `MachServices` key in the LaunchDaemon plist.
public let kPixelDancerPowerHelperMachServiceName = "com.vm.PixelDancerPowerHelper.daemon"

/// Bundle identifier of the helper daemon's plist as registered with
/// SMAppService. Used by both the installer GUI and (for diagnostic
/// purposes) the main app.
public let kPixelDancerPowerHelperDaemonPlistName = "com.vm.PixelDancerPowerHelper.daemon.plist"

/// Versioning for the wire protocol. Bump if the protocol changes in a
/// way that breaks compatibility — the main app refuses to talk to a
/// daemon reporting a lower version.
public let kPixelDancerPowerHelperProtocolVersion = 1

/// XPC interface exposed by the privileged daemon to the sandboxed main
/// app. All methods are asynchronous (via reply blocks) — NSXPCConnection
/// handles the cross-process hop.
///
/// All methods are `@objc` because NSXPCInterface requires Objective-C
/// compatibility.
@objc public protocol PowerHelperProtocol {

    /// Pings the daemon. Replies with the protocol version it implements
    /// and a short identifying string. Use to verify the daemon is alive
    /// and at the expected version.
    func ping(reply: @escaping (Int, String) -> Void)

    /// Enables `pmset disablesleep 1` (system stays awake including with
    /// the lid closed). The daemon shells out to `/usr/bin/pmset` as root.
    ///
    /// - reply: `(success: Bool, errorMessage: String?)`. On success the
    ///   system flag is now set; on failure the message describes what
    ///   went wrong at the daemon level (pmset non-zero exit, exec
    ///   failure, etc.). Either branch is final.
    func enableSleepOverride(reply: @escaping (Bool, String?) -> Void)

    /// Disables the override (`pmset disablesleep 0`). Symmetrical to
    /// `enableSleepOverride` — same reply semantics.
    func disableSleepOverride(reply: @escaping (Bool, String?) -> Void)

    /// Reports whether the override is currently active (parsed from
    /// `pmset -g | grep SleepDisabled`). Returns `(currentlyEnabled,
    /// rawPmsetSnippet)` so the main app can surface a precise UI status
    /// and diagnostic data without itself running pmset.
    func currentStatus(reply: @escaping (Bool, String) -> Void)
}
