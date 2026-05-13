//
//  UpdateInstaller.swift
//  PixelDancer Power Helper
//
//  Inline updater. Because the Helper GUI is not sandboxed, we can fetch
//  the new DMG via URLSession into the system temp directory and ask
//  Finder to open it directly — macOS auto-mounts and shows the standard
//  drag-to-Applications view. The user replaces the old app with the new
//  one and relaunches.
//

import AppKit
import Foundation

@MainActor
@Observable
final class UpdateInstaller {

    enum State: Equatable, Sendable {
        case idle
        case downloading(progress: Double)
        case opening
        case finished
        case failed(String)
    }

    private(set) var state: State = .idle

    private var task: URLSessionDownloadTask?

    func cancel() {
        task?.cancel()
        task = nil
        state = .idle
    }

    /// Downloads the asset at `url` into the system temp directory, then
    /// opens it. On a DMG that means it auto-mounts in Finder.
    func downloadAndOpen(dmgURL: URL) {
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
                    self.state = .failed("Download finished without a file")
                    return
                }
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    self.state = .failed("Server returned HTTP \(http.statusCode)")
                    return
                }
                self.state = .opening
                self.relocateAndOpen(downloadedAt: tmp)
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

    private func relocateAndOpen(downloadedAt source: URL) {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("PixelDancerPowerHelper-update.dmg")
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: source, to: dest)
        } catch {
            do {
                try FileManager.default.copyItem(at: source, to: dest)
            } catch let copyError {
                state = .failed("Couldn't stage DMG: \(copyError.localizedDescription)")
                return
            }
        }
        if NSWorkspace.shared.open(dest) {
            state = .finished
        } else {
            state = .failed("Couldn't open the DMG at \(dest.path)")
        }
    }
}
