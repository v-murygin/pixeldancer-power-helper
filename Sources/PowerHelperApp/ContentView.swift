//
//  ContentView.swift
//  PixelDancerPowerHelper GUI
//

import SwiftUI
import ServiceManagement
import PowerHelperShared

struct ContentView: View {

    @State private var status: SMAppService.Status = .notRegistered
    @State private var daemonReachable: Bool = false
    @State private var daemonProtocolVersion: Int?
    @State private var lastError: String?
    @State private var statusRefreshTask: Task<Void, Never>?
    @State private var pingConnection: NSXPCConnection?
    @State private var updateChecker = UpdateChecker()
    @State private var updateInstaller = UpdateInstaller()

    private let daemonService = SMAppService.daemon(plistName: kPixelDancerPowerHelperDaemonPlistName)

    var body: some View {
        VStack(spacing: 20) {
            header
            if case .updateAvailable(let installed, let latest, let url) = updateChecker.state {
                updateBanner(installed: installed, latest: latest, releaseURL: url)
            }
            statusCard
            actionsRow
            if let error = lastError {
                errorCard(error)
            }
            footer
        }
        .padding(28)
        .onAppear {
            refreshStatus()
            startPolling()
        }
        .onDisappear { statusRefreshTask?.cancel() }
        .task {
            await updateChecker.checkForUpdate()
        }
    }

    private func updateBanner(installed: String, latest: String, releaseURL: URL) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundStyle(.blue)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Update available — v\(latest)")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("You're on v\(installed)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                updateAction(latest: latest, releaseURL: releaseURL)
            }
        }
        .padding(12)
        .background(Color.blue.opacity(0.10), in: .rect(cornerRadius: 10))
    }

    @ViewBuilder
    private func updateAction(latest: String, releaseURL: URL) -> some View {
        switch updateInstaller.state {
        case .idle:
            HStack(spacing: 8) {
                Button {
                    let dmgURL = URL(string: "https://github.com/v-murygin/pixeldancer-power-helper/releases/download/v\(latest)/PixelDancerPowerHelper.dmg")
                        ?? URL(string: "https://github.com/v-murygin/pixeldancer-power-helper/releases/latest/download/PixelDancerPowerHelper.dmg")!
                    updateInstaller.downloadAndOpen(dmgURL: dmgURL)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Update")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Link(destination: releaseURL) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                }
                .help("Release notes on GitHub")
            }

        case .downloading(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress, total: 1.0)
                    .frame(width: 120)
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("Cancel") { updateInstaller.cancel() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

        case .opening:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Opening…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .finished:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Drag the new helper to Applications")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .failed(let msg):
            VStack(alignment: .trailing, spacing: 4) {
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Button("Retry") {
                        let dmgURL = URL(string: "https://github.com/v-murygin/pixeldancer-power-helper/releases/download/v\(latest)/PixelDancerPowerHelper.dmg")
                            ?? URL(string: "https://github.com/v-murygin/pixeldancer-power-helper/releases/latest/download/PixelDancerPowerHelper.dmg")!
                        updateInstaller.downloadAndOpen(dmgURL: dmgURL)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Link("Open in browser", destination: releaseURL).font(.caption)
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "battery.100.bolt")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
                .frame(width: 64, height: 64)
                .background(Color.accentColor.opacity(0.12), in: .circle)
            Text("PixelDancer Power Helper")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Enables closed-lid sleep prevention for PixelDancer Agent Mode")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Status card

    private var statusCard: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusTint)
                    .font(.title3)
                Text(statusHeadline)
                    .font(.headline)
                Spacer()
            }
            if !statusDetail.isEmpty {
                HStack {
                    Text(statusDetail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .padding(16)
        .background(statusTint.opacity(0.10), in: .rect(cornerRadius: 10))
    }

    private var statusIcon: String {
        if daemonReachable { return "checkmark.seal.fill" }
        switch status {
        case .enabled: return "ellipsis.circle.fill"
        case .requiresApproval: return "exclamationmark.circle.fill"
        case .notFound: return "xmark.octagon.fill"
        case .notRegistered: return "tray.and.arrow.down"
        @unknown default: return "questionmark.circle"
        }
    }

    private var statusTint: Color {
        if daemonReachable { return .green }
        switch status {
        case .enabled: return .blue
        case .requiresApproval: return .orange
        case .notFound: return .red
        case .notRegistered: return .secondary
        @unknown default: return .secondary
        }
    }

    private var statusHeadline: String {
        if daemonReachable {
            return String(localized: "Helper installed and running")
        }
        switch status {
        case .enabled:
            return String(localized: "Registered — waiting for daemon to come online")
        case .requiresApproval:
            return String(localized: "Approval required in System Settings")
        case .notFound:
            return String(localized: "Daemon plist not found")
        case .notRegistered:
            return String(localized: "Helper not installed")
        @unknown default:
            return String(localized: "Unknown status")
        }
    }

    private var statusDetail: String {
        if daemonReachable, let v = daemonProtocolVersion {
            return String(localized: "Daemon protocol v\(v). Closed-lid sleep prevention works in PixelDancer Agent Mode.")
        }
        switch status {
        case .requiresApproval:
            return String(localized: "Open System Settings → Login Items & Extensions, find 'PixelDancer Power Helper Daemon', toggle it on.")
        case .notRegistered:
            return String(localized: "Click Install to register the daemon with macOS.")
        case .notFound:
            return String(localized: "Reinstall the Power Helper — the bundled plist is missing.")
        case .enabled:
            return String(localized: "Daemon registered. If this status persists for more than 30 seconds, restart the Mac.")
        @unknown default:
            return ""
        }
    }

    // MARK: - Actions

    private var actionsRow: some View {
        HStack(spacing: 12) {
            if status == .requiresApproval {
                Button {
                    SMAppService.openSystemSettingsLoginItems()
                } label: {
                    Label("Open System Settings", systemImage: "gear")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else if status == .notRegistered || status == .notFound {
                Button {
                    install()
                } label: {
                    Label("Install", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else if status == .enabled || daemonReachable {
                Button {
                    uninstall()
                } label: {
                    Label("Uninstall", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            Button {
                refreshStatus()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    // MARK: - Error card

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.orange.opacity(0.10), in: .rect(cornerRadius: 8))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("After installing, you can quit this app — the helper runs in the background.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Status / actions

    private func refreshStatus() {
        status = daemonService.status
        pingDaemon()
    }

    private func startPolling() {
        statusRefreshTask?.cancel()
        statusRefreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await MainActor.run { refreshStatus() }
            }
        }
    }

    private func install() {
        lastError = nil
        do {
            try daemonService.register()
            refreshStatus()
            // If the install requires approval, point the user to System Settings.
            if daemonService.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch {
            lastError = "Install failed: \(error.localizedDescription)"
        }
    }

    private func uninstall() {
        lastError = nil
        do {
            try daemonService.unregister()
            refreshStatus()
        } catch {
            lastError = "Uninstall failed: \(error.localizedDescription)"
        }
    }

    private func pingDaemon() {
        // The XPC connection MUST outlive the asynchronous ping call. Don't
        // invalidate it inside the reply block — the reply runs on a private
        // queue and dropping the connection there races with delivery, so
        // the reply handler never fires on the calling actor. Keep the
        // connection alive in @State until the next ping replaces it.
        let connection = NSXPCConnection(
            machServiceName: kPixelDancerPowerHelperMachServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: PowerHelperProtocol.self)
        connection.resume()

        // Replace any previous in-flight ping connection so we don't leak.
        let previousConnection = pingConnection
        pingConnection = connection
        previousConnection?.invalidate()

        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            DispatchQueue.main.async {
                daemonReachable = false
                daemonProtocolVersion = nil
            }
        } as? PowerHelperProtocol

        proxy?.ping { version, name in
            DispatchQueue.main.async {
                daemonReachable = true
                daemonProtocolVersion = version
            }
        }
    }
}

#Preview {
    ContentView()
}
