//
//  UpdateInstaller.swift
//  PixelDancer Power Helper
//
//  Full-loop inline updater. Because the Helper GUI is not sandboxed it can:
//
//    1. Download the new DMG via URLSession (already worked in v1.0.5).
//    2. Mount it silently with `hdiutil attach -nobrowse`.
//    3. Verify the new .app's code signature and Team Identifier — must
//       match the currently running build, otherwise we refuse to install.
//       This blocks the obvious "wrong-team malicious DMG" attack.
//    4. Atomically replace `/Applications/PixelDancer Power Helper.app`
//       (copy to a hidden temp dir next to it, swap, trash the old bundle).
//    5. Unmount the DMG and relaunch the new app, then quit ourselves.
//
//  The daemon (root LaunchDaemon) keeps running with its old binary in
//  memory; launchd will load the new binary the next time it restarts the
//  service. For UI-only updates that's fine — the XPC protocol version
//  doesn't change. Future protocol-breaking changes would need an explicit
//  daemon re-register here.
//

import AppKit
import Foundation

@MainActor
@Observable
final class UpdateInstaller {

    enum State: Equatable, Sendable {
        case idle
        case downloading(progress: Double)
        case installing       // mounting / verifying / swapping
        case relaunching
        case failed(String)
    }

    enum InstallError: LocalizedError {
        case mountFailed(String)
        case appNotFound
        case signatureInvalid(String)
        case teamIDMismatch(expected: String, got: String)
        case replaceFailed(String)
        case relaunchFailed(String)

        var errorDescription: String? {
            switch self {
            case .mountFailed(let detail):
                return "Couldn't mount the DMG. \(detail)"
            case .appNotFound:
                return "Couldn't find PixelDancer Power Helper.app inside the DMG."
            case .signatureInvalid(let detail):
                return "New build's signature didn't verify. \(detail)"
            case .teamIDMismatch(let expected, let got):
                return "Refusing to install: expected Developer ID team '\(expected)', got '\(got)'."
            case .replaceFailed(let detail):
                return "Couldn't replace the installed app. \(detail)"
            case .relaunchFailed(let detail):
                return "Update installed but relaunch failed. \(detail)"
            }
        }
    }

    private(set) var state: State = .idle

    private var task: URLSessionDownloadTask?

    /// Where the installed Helper lives. Hardcoded — DMG bundles the .app
    /// at the root and points users at /Applications, so this is also where
    /// the previous version is.
    nonisolated private static let installedAppPath = "/Applications/PixelDancer Power Helper.app"

    func cancel() {
        task?.cancel()
        task = nil
        state = .idle
    }

    /// One-shot: download, verify, swap, relaunch.
    func downloadAndInstall(dmgURL: URL) {
        cancel()
        state = .downloading(progress: 0)

        let download = URLSession.shared.downloadTask(with: dmgURL) { [weak self] tmp, response, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.state = .failed("Download failed: \(error.localizedDescription)")
                    return
                }
                guard let tmp else {
                    self.state = .failed("Download finished without a file.")
                    return
                }
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    self.state = .failed("Server returned HTTP \(http.statusCode).")
                    return
                }
                await self.runInstall(downloadedAt: tmp)
            }
        }

        let observation = download.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            Task { @MainActor in
                guard let self else { return }
                if case .downloading = self.state {
                    self.state = .downloading(progress: progress.fractionCompleted)
                }
            }
        }
        objc_setAssociatedObject(
            download,
            Unmanaged.passUnretained(self).toOpaque(),
            observation,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )

        task = download
        download.resume()
    }

    private func runInstall(downloadedAt source: URL) async {
        state = .installing

        // Stage the DMG at a stable temp path before we hand it to detached
        // work — the URLSession-provided tmp file gets deleted as soon as
        // the completion handler returns.
        let dmgURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PixelDancerPowerHelper-update.dmg")
        try? FileManager.default.removeItem(at: dmgURL)
        do {
            try FileManager.default.moveItem(at: source, to: dmgURL)
        } catch {
            do {
                try FileManager.default.copyItem(at: source, to: dmgURL)
            } catch let copyError {
                state = .failed("Couldn't stage DMG: \(copyError.localizedDescription)")
                return
            }
        }

        // Heavy lifting off the main actor so the UI keeps redrawing the
        // "Installing…" indicator.
        let result: Result<Void, Error> = await Task.detached {
            do {
                let mountPoint = try Self.mountDMG(at: dmgURL)
                defer {
                    _ = try? Self.unmountDMG(at: mountPoint)
                    try? FileManager.default.removeItem(at: dmgURL)
                }

                let newAppURL = try Self.findApp(in: mountPoint)
                try Self.verifyCodeSignature(at: newAppURL)
                try Self.verifyTeamIDMatch(newAppURL: newAppURL)
                try Self.replaceInstalledApp(with: newAppURL)
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .failure(let error):
            state = .failed(error.localizedDescription)
        case .success:
            state = .relaunching
            do {
                try await relaunchInstalledApp()
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - DMG handling

    nonisolated private static func mountDMG(at dmgURL: URL) throws -> URL {
        let mountPoint = FileManager.default.temporaryDirectory
            .appendingPathComponent("PowerHelperUpdate-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        let result = try runCommand("/usr/bin/hdiutil", [
            "attach", "-nobrowse", "-readonly",
            "-mountpoint", mountPoint.path,
            dmgURL.path
        ])
        if result.status != 0 {
            throw InstallError.mountFailed(result.stderr.isEmpty ? "exit \(result.status)" : result.stderr)
        }
        return mountPoint
    }

    nonisolated private static func unmountDMG(at mountPoint: URL) throws {
        _ = try runCommand("/usr/bin/hdiutil", ["detach", "-force", mountPoint.path])
        try? FileManager.default.removeItem(at: mountPoint)
    }

    nonisolated private static func findApp(in mountPoint: URL) throws -> URL {
        let contents = try FileManager.default.contentsOfDirectory(
            at: mountPoint,
            includingPropertiesForKeys: nil
        )
        if let app = contents.first(where: {
            $0.pathExtension == "app" && $0.lastPathComponent.contains("Power Helper")
        }) {
            return app
        }
        throw InstallError.appNotFound
    }

    // MARK: - Code signing checks

    nonisolated private static func verifyCodeSignature(at appURL: URL) throws {
        let result = try runCommand("/usr/bin/codesign", [
            "-v", "--deep", "--strict", appURL.path
        ])
        if result.status != 0 {
            throw InstallError.signatureInvalid(result.stderr.isEmpty ? "exit \(result.status)" : result.stderr)
        }
    }

    /// Ensures the candidate .app and the currently running .app are signed
    /// by the same Developer ID team. Without this check a notarised DMG from
    /// any other developer could overwrite us.
    nonisolated private static func verifyTeamIDMatch(newAppURL: URL) throws {
        let expected = try teamID(at: Bundle.main.bundleURL)
        let got = try teamID(at: newAppURL)
        if expected != got {
            throw InstallError.teamIDMismatch(expected: expected, got: got)
        }
    }

    nonisolated private static func teamID(at url: URL) throws -> String {
        // codesign writes its info output to stderr.
        let result = try runCommand("/usr/bin/codesign", ["-dvv", url.path])
        let combined = result.stdout + "\n" + result.stderr
        for raw in combined.split(separator: "\n") {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("TeamIdentifier=") {
                let value = String(line.dropFirst("TeamIdentifier=".count))
                if value == "not set" {
                    throw InstallError.signatureInvalid("\(url.lastPathComponent) is not signed with a Team Identifier.")
                }
                return value
            }
        }
        throw InstallError.signatureInvalid("No TeamIdentifier in codesign output for \(url.lastPathComponent).")
    }

    // MARK: - Install swap

    nonisolated private static func replaceInstalledApp(with newAppURL: URL) throws {
        let installed = URL(fileURLWithPath: installedAppPath)
        let parent = installed.deletingLastPathComponent()
        let suffix = UUID().uuidString.prefix(8)
        let stagedNew = parent.appendingPathComponent(".PixelDancer-Power-Helper.new-\(suffix).app")
        let backup = parent.appendingPathComponent(".PixelDancer-Power-Helper.old-\(suffix).app")

        // 1. Copy the new bundle from the DMG into /Applications under a
        //    hidden name. Copy (not move) — DMG mount is read-only.
        try? FileManager.default.removeItem(at: stagedNew)
        do {
            try FileManager.default.copyItem(at: newAppURL, to: stagedNew)
        } catch {
            throw InstallError.replaceFailed("copy into Applications: \(error.localizedDescription)")
        }

        // 2. Move the old bundle aside (if present).
        let existed = FileManager.default.fileExists(atPath: installed.path)
        if existed {
            do {
                try FileManager.default.moveItem(at: installed, to: backup)
            } catch {
                try? FileManager.default.removeItem(at: stagedNew)
                throw InstallError.replaceFailed("backup current app: \(error.localizedDescription)")
            }
        }

        // 3. Promote the new bundle into place.
        do {
            try FileManager.default.moveItem(at: stagedNew, to: installed)
        } catch {
            // Roll back: put the old one back, drop the staged copy.
            if existed {
                try? FileManager.default.moveItem(at: backup, to: installed)
            }
            try? FileManager.default.removeItem(at: stagedNew)
            throw InstallError.replaceFailed("promote new app: \(error.localizedDescription)")
        }

        // 4. Trash the previous bundle. We don't wait or error on this —
        //    if it sticks around as `.PixelDancer-Power-Helper.old-…app`
        //    Finder cleans it up later, and macOS won't launch a hidden
        //    bundle accidentally.
        if existed {
            try? FileManager.default.removeItem(at: backup)
        }
    }

    // MARK: - Relaunch

    private func relaunchInstalledApp() async throws {
        let installed = URL(fileURLWithPath: Self.installedAppPath)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.createsNewApplicationInstance = false

        do {
            _ = try await NSWorkspace.shared.openApplication(at: installed, configuration: config)
        } catch {
            throw InstallError.relaunchFailed(error.localizedDescription)
        }

        // Give the new instance one runloop tick to come up, then bow out.
        // Quitting earlier sometimes races and macOS marks the new launch
        // as a "duplicate instance was already running" no-op.
        try? await Task.sleep(for: .milliseconds(800))
        NSApp.terminate(nil)
    }

    // MARK: - Process helper

    nonisolated private struct CommandResult: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    nonisolated private static func runCommand(_ path: String, _ args: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return CommandResult(status: process.terminationStatus, stdout: out, stderr: err)
    }
}
