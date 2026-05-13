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

    /// Three-step progress: Installed (SMAppService registered) → Approved
    /// (user toggled the Login Item) → Running (XPC ping succeeded).
    private var currentStep: Int {
        if daemonReachable { return 3 }
        switch status {
        case .enabled: return 2          // approved, waiting for daemon to come online
        case .requiresApproval: return 1 // installed, needs approval
        case .notRegistered, .notFound: return 0
        @unknown default: return 0
        }
    }

    var body: some View {
        VStack(spacing: 18) {
            header

            if case .updateAvailable(let installed, let latest, let url) = updateChecker.state {
                updateBanner(installed: installed, latest: latest, releaseURL: url)
            }

            stepsRow

            statusBlock

            primaryActions

            if let error = lastError {
                errorCard(error)
            }

            footer
        }
        .padding(28)
        .frame(width: 540)
        .onAppear {
            refreshStatus()
            startPolling()
        }
        .onDisappear { statusRefreshTask?.cancel() }
        .task {
            await updateChecker.checkForUpdate()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "battery.100.bolt")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 52, height: 52)
                .background(Color.accentColor.opacity(0.14), in: .circle)

            VStack(alignment: .leading, spacing: 2) {
                Text("PixelDancer Power Helper")
                    .font(.headline)
                Text("Enables closed-lid sleep prevention for PixelDancer Agent Mode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
    }

    // MARK: - Stepped progress

    private var stepsRow: some View {
        HStack(spacing: 0) {
            stepNode(index: 0, label: "Installed")
            stepConnector(filled: currentStep > 0)
            stepNode(index: 1, label: "Approved")
            stepConnector(filled: currentStep > 1)
            stepNode(index: 2, label: "Running")
        }
        .padding(.vertical, 6)
    }

    private func stepNode(index: Int, label: String) -> some View {
        let isDone = currentStep > index
        let isCurrent = currentStep == index
        let isRunning = index == 2 && daemonReachable

        let circleFill: Color = isDone ? .green : (isCurrent ? .blue : Color.gray.opacity(0.25))
        let circleBorder: Color = isDone || isCurrent ? .clear : Color.gray.opacity(0.4)

        return VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(circleFill)
                    .frame(width: 26, height: 26)
                    .overlay(Circle().stroke(circleBorder, lineWidth: 1.5))

                if isRunning {
                    // Pulsing dot while daemon is alive — visual "heartbeat".
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .symbolEffect(.pulse, options: .repeating, isActive: true)
                } else if isDone {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                } else if isCurrent {
                    Circle()
                        .fill(.white)
                        .frame(width: 8, height: 8)
                        .symbolEffect(.pulse, options: .repeating, isActive: true)
                }
            }

            Text(label)
                .font(.caption2)
                .fontWeight(isCurrent ? .semibold : .regular)
                .foregroundStyle(isDone || isCurrent ? .primary : .secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func stepConnector(filled: Bool) -> some View {
        Rectangle()
            .fill(filled ? Color.green : Color.gray.opacity(0.25))
            .frame(height: 2)
            .padding(.bottom, 20)   // align vertically with circle centres
    }

    // MARK: - Status block

    private var statusBlock: some View {
        VStack(spacing: 6) {
            Text(statusHeadline)
                .font(.subheadline)
                .fontWeight(.semibold)
            Text(statusDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(statusBackgroundColor.opacity(0.10), in: .rect(cornerRadius: 10))
    }

    private var statusBackgroundColor: Color {
        if daemonReachable { return .green }
        switch status {
        case .enabled: return .blue
        case .requiresApproval: return .orange
        case .notFound: return .red
        case .notRegistered: return .gray
        @unknown default: return .gray
        }
    }

    private var statusHeadline: String {
        if daemonReachable {
            return String(localized: "Helper is running")
        }
        switch status {
        case .enabled:
            return String(localized: "Waiting for daemon to come online")
        case .requiresApproval:
            return String(localized: "Approval required")
        case .notFound:
            return String(localized: "Daemon plist not found")
        case .notRegistered:
            return String(localized: "Not installed yet")
        @unknown default:
            return String(localized: "Unknown status")
        }
    }

    private var statusDetail: String {
        if daemonReachable, let v = daemonProtocolVersion {
            return String(localized: "Closed-lid sleep prevention is active. Protocol v\(v).")
        }
        switch status {
        case .requiresApproval:
            return String(localized: "Open System Settings → Login Items & Extensions and toggle 'PixelDancer Power Helper Daemon' on.")
        case .notRegistered:
            return String(localized: "Click Install to register the daemon with macOS. You'll be asked to approve it once in System Settings.")
        case .notFound:
            return String(localized: "Reinstall the Power Helper — the bundled plist is missing.")
        case .enabled:
            return String(localized: "Daemon registered. If this persists for more than 30 seconds, try Refresh or restart the Mac.")
        @unknown default:
            return ""
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var primaryActions: some View {
        HStack(spacing: 10) {
            Spacer()
            primaryActionButton
            Button {
                refreshStatus()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            Spacer()
        }
    }

    @ViewBuilder
    private var primaryActionButton: some View {
        switch (status, daemonReachable) {
        case (.requiresApproval, _):
            Button {
                SMAppService.openSystemSettingsLoginItems()
            } label: {
                Label("Open System Settings", systemImage: "gear")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)

        case (.notRegistered, _), (.notFound, _):
            Button {
                install()
            } label: {
                Label("Install", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)

        case (.enabled, _):
            Button {
                uninstall()
            } label: {
                Label("Uninstall", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

        @unknown default:
            EmptyView()
        }
    }

    // MARK: - Update banner

    private func updateBanner(installed: String, latest: String, releaseURL: URL) -> some View {
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
        .padding(12)
        .background(Color.blue.opacity(0.10), in: .rect(cornerRadius: 10))
    }

    @ViewBuilder
    private func updateAction(latest: String, releaseURL: URL) -> some View {
        switch updateInstaller.state {
        case .idle:
            HStack(spacing: 8) {
                Button {
                    updateInstaller.downloadAndInstall(dmgURL: dmgURL(for: latest))
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Update")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Link(destination: releaseURL) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                }
                .help("Release notes on GitHub")
            }

        case .downloading(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress, total: 1.0).frame(width: 120)
                Text("\(Int(progress * 100))%")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Button("Cancel") { updateInstaller.cancel() }
                    .buttonStyle(.bordered).controlSize(.small)
            }

        case .installing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Installing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .relaunching:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Installed — relaunching")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .failed(let msg):
            VStack(alignment: .trailing, spacing: 4) {
                Text(msg).font(.caption2).foregroundStyle(.orange).lineLimit(3)
                HStack(spacing: 6) {
                    Button("Retry") {
                        updateInstaller.downloadAndInstall(dmgURL: dmgURL(for: latest))
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    Link("Open in browser", destination: releaseURL).font(.caption)
                }
            }
        }
    }

    /// Versioned DMG URL with a fallback to the `latest/download` alias so
    /// we always have something to retry against even if the exact tag URL
    /// 404s during release propagation.
    private func dmgURL(for latest: String) -> URL {
        URL(string: "https://github.com/v-murygin/pixeldancer-power-helper/releases/download/v\(latest)/PixelDancerPowerHelper.dmg")
            ?? URL(string: "https://github.com/v-murygin/pixeldancer-power-helper/releases/latest/download/PixelDancerPowerHelper.dmg")!
    }

    // MARK: - Error / footer

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.orange.opacity(0.10), in: .rect(cornerRadius: 8))
    }

    private var footer: some View {
        HStack {
            Text("After installing, you can quit this app — the helper runs in the background.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Text(appVersionLabel)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
    }

    /// "v1.0.5 (6)" — short version + build number from Info.plist, surfaced
    /// in the footer so users (and us, in screenshots) know which build is
    /// running without opening About.
    private var appVersionLabel: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "v\(short) (\(build))"
    }

    // MARK: - Status / actions wiring

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
        let connection = NSXPCConnection(
            machServiceName: kPixelDancerPowerHelperMachServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: PowerHelperProtocol.self)
        connection.resume()

        let previousConnection = pingConnection
        pingConnection = connection
        previousConnection?.invalidate()

        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
            DispatchQueue.main.async {
                daemonReachable = false
                daemonProtocolVersion = nil
            }
        } as? PowerHelperProtocol

        proxy?.ping { version, _ in
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
