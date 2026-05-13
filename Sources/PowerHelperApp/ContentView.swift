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

    private let daemonService = SMAppService.daemon(plistName: kPixelDancerPowerHelperDaemonPlistName)

    var body: some View {
        VStack(spacing: 24) {
            header
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
            return "Helper installed and running"
        }
        switch status {
        case .enabled:
            return "Registered — waiting for daemon to come online"
        case .requiresApproval:
            return "Approval required in System Settings"
        case .notFound:
            return "Daemon plist not found"
        case .notRegistered:
            return "Helper not installed"
        @unknown default:
            return "Unknown status"
        }
    }

    private var statusDetail: String {
        if daemonReachable, let v = daemonProtocolVersion {
            return "Daemon protocol v\(v). Closed-lid sleep prevention works in PixelDancer Agent Mode."
        }
        switch status {
        case .requiresApproval:
            return "Open System Settings → Login Items & Extensions, find 'PixelDancer Power Helper Daemon', toggle it on."
        case .notRegistered:
            return "Click Install to register the daemon with macOS."
        case .notFound:
            return "Reinstall the Power Helper — the bundled plist is missing."
        case .enabled:
            return "Daemon registered. If this status persists for more than 30 seconds, restart the Mac."
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
