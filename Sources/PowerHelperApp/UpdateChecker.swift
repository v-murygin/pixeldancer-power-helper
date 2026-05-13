//
//  UpdateChecker.swift
//  PixelDancer Power Helper
//
//  Checks GitHub Releases for a newer version on launch and every few
//  hours after. The Helper GUI is not sandboxed so a plain HTTPS request
//  needs no entitlement.
//

import Foundation

@MainActor
@Observable
final class UpdateChecker {

    enum State: Equatable, Sendable {
        case unknown
        case checking
        case upToDate(installed: String)
        case updateAvailable(installed: String, latest: String, releaseURL: URL)
        case failed(String)
    }

    private(set) var state: State = .unknown

    private static let apiURL = URL(string: "https://api.github.com/repos/v-murygin/pixeldancer-power-helper/releases/latest")!
    private static let lastCheckedKey = "UpdateChecker.lastChecked"
    private static let cacheInterval: TimeInterval = 6 * 3600  // 6 hours

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func checkForUpdate(force: Bool = false) async {
        let installed = installedVersion()

        if !force,
           let last = userDefaults.object(forKey: Self.lastCheckedKey) as? Date,
           Date().timeIntervalSince(last) < Self.cacheInterval,
           state != .unknown {
            return
        }

        state = .checking

        do {
            var request = URLRequest(url: Self.apiURL)
            request.httpMethod = "GET"
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("PixelDancerPowerHelper", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 10

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                state = .failed("GitHub API returned HTTP \(code)")
                return
            }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            userDefaults.set(Date(), forKey: Self.lastCheckedKey)

            let latestVersion = release.tagName.hasPrefix("v")
                ? String(release.tagName.dropFirst())
                : release.tagName

            if Self.isOlder(installed: installed, than: latestVersion) {
                let releaseURL = URL(string: release.htmlUrl) ?? Self.apiURL
                state = .updateAvailable(installed: installed, latest: latestVersion, releaseURL: releaseURL)
            } else {
                state = .upToDate(installed: installed)
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// The Helper's own `CFBundleShortVersionString` from its Info.plist.
    func installedVersion() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }

    /// Returns true when `installed` is strictly older than `latest` using
    /// numeric segment comparison (`1.0.10` correctly sorts after `1.0.9`).
    static func isOlder(installed: String, than latest: String) -> Bool {
        installed.compare(latest, options: .numeric) == .orderedAscending
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlUrl: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlUrl = "html_url"
        }
    }
}
