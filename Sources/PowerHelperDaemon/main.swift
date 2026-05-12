//
//  main.swift
//  PixelDancerPowerHelperDaemon
//
//  Privileged LaunchDaemon: runs as root, listens on a Mach service, exposes
//  the PowerHelperProtocol XPC interface. The sandboxed PixelDancer.app
//  connects by Mach service name and invokes pmset on our behalf.
//
//  Started by launchd via the embedded plist (installed via SMAppService by
//  the user-facing PixelDancerPowerHelper.app on first launch).
//

import Foundation
import os.log
import PowerHelperShared

let logger = Logger(subsystem: "com.vm.PixelDancerPowerHelper.daemon", category: "main")

// MARK: - Service implementation

final class PowerHelperService: NSObject, PowerHelperProtocol {

    func ping(reply: @escaping (Int, String) -> Void) {
        logger.info("ping()")
        reply(kPixelDancerPowerHelperProtocolVersion, "PixelDancerPowerHelperDaemon")
    }

    func enableSleepOverride(reply: @escaping (Bool, String?) -> Void) {
        logger.info("enableSleepOverride()")
        runPmset(args: ["-a", "disablesleep", "1"], reply: reply)
    }

    func disableSleepOverride(reply: @escaping (Bool, String?) -> Void) {
        logger.info("disableSleepOverride()")
        runPmset(args: ["-a", "disablesleep", "0"], reply: reply)
    }

    func currentStatus(reply: @escaping (Bool, String) -> Void) {
        logger.info("currentStatus()")
        let output = runPmsetCapture(args: ["-g"]) ?? ""
        // Parse "SleepDisabled  1" / "SleepDisabled  0" from `pmset -g`.
        var enabled = false
        var snippet = ""
        for line in output.split(whereSeparator: { $0 == "\n" }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().contains("sleepdisabled") {
                snippet = trimmed
                let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
                if let last = parts.last, last == "1" { enabled = true }
                break
            }
        }
        reply(enabled, snippet)
    }

    // MARK: - Process execution

    /// We deliberately invoke `/usr/bin/pmset` by full path with explicit
    /// args — no shell, no env injection. Reduces attack surface from a
    /// hypothetical compromised client that might try to smuggle commands.
    private func runPmset(args: [String], reply: @escaping (Bool, String?) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            logger.error("pmset run failed: \(String(describing: error))")
            reply(false, "Failed to execute /usr/bin/pmset: \(error.localizedDescription)")
            return
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        if process.terminationStatus == 0 {
            logger.info("pmset \(args.joined(separator: " ")) ok")
            reply(true, output.isEmpty ? nil : output)
        } else {
            logger.error("pmset exit \(process.terminationStatus): \(output)")
            reply(false, "pmset exited \(process.terminationStatus): \(output)")
        }
    }

    private func runPmsetCapture(args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - XPC listener

/// `NSXPCListenerDelegate` implementation that pins the exported
/// interface and accepts incoming connections. The daemon trusts any
/// caller that can reach its Mach service — macOS already gates Mach
/// service lookup by application requirements on Sequoia 15+, so we
/// don't need additional client validation at this layer.
final class XPCListenerDelegate: NSObject, NSXPCListenerDelegate {

    private let service = PowerHelperService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        logger.info("incoming XPC connection")
        newConnection.exportedInterface = NSXPCInterface(with: PowerHelperProtocol.self)
        newConnection.exportedObject = service
        newConnection.invalidationHandler = {
            logger.info("XPC connection invalidated")
        }
        newConnection.interruptionHandler = {
            logger.info("XPC connection interrupted")
        }
        newConnection.resume()
        return true
    }
}

// MARK: - Main

logger.info("PixelDancerPowerHelperDaemon starting (protocol v\(kPixelDancerPowerHelperProtocolVersion))")

let delegate = XPCListenerDelegate()
let listener = NSXPCListener(machServiceName: kPixelDancerPowerHelperMachServiceName)
listener.delegate = delegate
listener.resume()

logger.info("Listening on Mach service: \(kPixelDancerPowerHelperMachServiceName)")

// Park the daemon main thread. launchd keeps the process alive; the XPC
// listener handles all real work on its own queues.
RunLoop.main.run()
