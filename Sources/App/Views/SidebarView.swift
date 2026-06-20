import SwiftUI
import LibvirtKit

struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @Binding var selection: SidebarSelection?
    var onAdd: () -> Void
    var onEdit: (ConnectionConfig) -> Void
    var onNewVM: (ConnectionSession) -> Void
    var onDeleteVM: (ConnectionSession, DomainSummary) -> Void
    var onCloneVM: (ConnectionSession, DomainSummary) -> Void

    @State private var searchText = ""

    var body: some View {
        List(selection: $selection) {
            ForEach(appState.sessions) { session in
                SessionSection(session: session, searchText: searchText, selection: $selection,
                               onEdit: onEdit, onNewVM: onNewVM, onDeleteVM: onDeleteVM,
                               onCloneVM: onCloneVM)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Virtual Machines")
        .searchable(text: $searchText, prompt: "Filter VMs")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    newVMMenuItems
                    Divider()
                    Button { onAdd() } label: {
                        Label("Add Connection…", systemImage: "link.badge.plus")
                    }
                } label: { Label("Add", systemImage: "plus") }
                .help("Create a new virtual machine or add a connection")
            }
        }
    }

    @ViewBuilder private var newVMMenuItems: some View {
        let connected = appState.sessions.filter(\.isConnected)
        if connected.count == 1 {
            Button { onNewVM(connected[0]) } label: {
                Label("New Virtual Machine…", systemImage: "desktopcomputer")
            }
        } else if connected.count > 1 {
            ForEach(connected) { s in
                Button { onNewVM(s) } label: {
                    Label("New Virtual Machine on \(s.config.name)…", systemImage: "desktopcomputer")
                }
            }
        } else {
            Button {} label: { Label("New Virtual Machine…", systemImage: "desktopcomputer") }
                .disabled(true)
        }
    }
}

private struct SessionSection: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var session: ConnectionSession
    let searchText: String
    @Binding var selection: SidebarSelection?
    var onEdit: (ConnectionConfig) -> Void
    var onNewVM: (ConnectionSession) -> Void
    var onDeleteVM: (ConnectionSession, DomainSummary) -> Void
    var onCloneVM: (ConnectionSession, DomainSummary) -> Void

    private var filteredDomains: [DomainSummary] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return session.domains }
        return session.domains.filter {
            $0.name.lowercased().contains(q) || $0.uuid.lowercased().contains(q)
            || $0.state.label.lowercased().contains(q)
        }
    }

    var body: some View {
        Section {
            hostRow
                .tag(SidebarSelection.host(session.id))
                .contextMenu { contextMenu }

            switch session.status {
            case .connecting:
                Label("Connecting…", systemImage: "ellipsis")
                    .foregroundStyle(.secondary)
            case .failed(let msg):
                VStack(alignment: .leading, spacing: 4) {
                    Label(msg, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red).lineLimit(3)
                    Button("Retry") { reconnect() }
                        .buttonStyle(.link).font(.caption)
                }
            case .disconnected:
                Button {
                    Task { await session.connect() }
                } label: {
                    Label("Connect", systemImage: "bolt")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            case .reconnecting:
                Label("Connection lost — reconnecting…", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
                domainRows
            case .connected:
                if session.domains.isEmpty {
                    Text("No VMs").foregroundStyle(.secondary)
                } else if filteredDomains.isEmpty {
                    Text("No matches").foregroundStyle(.secondary)
                } else {
                    domainRows
                }
            }
        }
    }

    /// Selectable connection/host row: name, key stats, status, and the ⋯ menu.
    private var hostRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "server.rack")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.config.name).fontWeight(.semibold)
                hostStatsCaption
            }
            Spacer(minLength: 0)
            statusDot
            Menu { contextMenu } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .padding(.trailing, 4)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var hostStatsCaption: some View {
        if session.isConnected {
            let running = session.domains.filter(\.isActive).count
            let defined = session.domains.count
            Group {
                if let mem = session.hostMemoryStats ?? session.hostSummary?.memory,
                   let used = mem.usedKiB,
                   let total = mem.totalKiB ?? session.hostSummary?.node.memoryKiB {
                    Text("\(Format.memory(kiB: used)) of \(Format.memory(kiB: total)) · \(running)/\(defined) running")
                } else {
                    Text("\(running)/\(defined) VMs running")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        } else {
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        switch session.status {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .disconnected: return "Disconnected"
        case .failed: return "Connection failed"
        }
    }

    @ViewBuilder private var domainRows: some View {
        ForEach(filteredDomains) { domain in
            DomainRow(
                domain: domain,
                stats: session.stats[domain.uuid],
                hasConfigDrift: domain.isActive && session.hasConfigDrift(uuid: domain.uuid))
                .padding(.leading, 12)
                .tag(SidebarSelection.vm(sessionID: session.id, uuid: domain.uuid))
                .contextMenu {
                    Button("Clone \(domain.name)…") { onCloneVM(session, domain) }
                    Divider()
                    Button("Delete \(domain.name)…", role: .destructive) {
                        onDeleteVM(session, domain)
                    }
                }
        }
    }

    @ViewBuilder private var statusDot: some View {
        switch session.status {
        case .connected:
            Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.green)
        case .connecting, .reconnecting:
            Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.yellow)
        case .failed:
            Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.red)
        case .disconnected:
            Image(systemName: "circle").font(.system(size: 6)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var contextMenu: some View {
        if session.isConnected {
            Button("New VM…") { onNewVM(session) }
            Divider()
            Button("Disconnect") { session.disconnect() }
            Button("Reconnect") { reconnect() }
        } else {
            Button("Connect") { Task { await session.connect() } }
        }
        Divider()
        Button("Edit…") { onEdit(session.config) }
        if !session.config.isBuiltIn {
            Button("Remove Connection", role: .destructive) {
                appState.removeConnection(id: session.id)
            }
        }
    }

    private func reconnect() {
        Task { session.disconnect(); await session.connect() }
    }
}

private struct DomainRow: View {
    let domain: DomainSummary
    var stats: ConnectionSession.VMStats?
    var hasConfigDrift: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: domain.state.symbol)
                .foregroundStyle(domain.state.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(domain.name)
                statsCaption
            }
            Spacer(minLength: 0)
            if hasConfigDrift {
                Image(systemName: "doc.badge.ellipsis")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("Running configuration differs from saved")
            }
        }
        .padding(.vertical, 2)
    }

    private var stateLabel: String {
        hasConfigDrift ? "\(domain.state.label) · unsaved" : domain.state.label
    }

    @ViewBuilder
    private var statsCaption: some View {
        if domain.isActive, let s = stats {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(stateLabel) · CPU \(Int(s.cpuPercent))% · RAM \(Format.memory(kiB: s.memUsedKiB))")
                Text("Disk read \(Format.rate(bytesPerSecond: s.diskReadBps)) · write \(Format.rate(bytesPerSecond: s.diskWriteBps))")
                Text("Net in \(Format.rate(bytesPerSecond: s.netRxBps)) · out \(Format.rate(bytesPerSecond: s.netTxBps))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(3)
        } else {
            Text(stateLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
