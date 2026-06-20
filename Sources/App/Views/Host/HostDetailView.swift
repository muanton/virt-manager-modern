import SwiftUI
import LibvirtKit

/// Tabbed detail for a connection's host — mirrors `DomainDetailView` for VMs.
/// Replaces the old Host Info / Manage Storage / Manage Networks modals.
struct HostDetailView: View {
    @ObservedObject var session: ConnectionSession
    @EnvironmentObject private var appState: AppState
    @State private var tab = 0

    private var tabKey: String { "host/\(session.id)" }

    var body: some View {
        TabView(selection: $tab) {
            HostInfoTab(session: session)
                .tabItem { Label("Info", systemImage: "info.circle") }.tag(0)
            StorageTab(session: session)
                .tabItem { Label("Storage", systemImage: "externaldrive") }.tag(1)
            NetworkTab(session: session)
                .tabItem { Label("Networks", systemImage: "network") }.tag(2)
        }
        .padding()
        .navigationTitle(session.config.name)
        .navigationSubtitle(subtitle)
        .onAppear { tab = appState.detailTabs[tabKey] ?? 0 }
        .onChange(of: tab) { _, newValue in appState.detailTabs[tabKey] = newValue }
    }

    private var subtitle: String {
        guard let host = session.hostSummary else {
            return session.isConnected ? "Connected" : "Not connected"
        }
        return "libvirt \(host.libvirtVersion) · \(host.node.cpus) CPUs · "
             + "\(host.runningCount)/\(host.domainCount) running"
    }
}
