import SwiftUI
import LibvirtKit

struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @Binding var selection: DomainSelection?
    var onAdd: () -> Void
    var onEdit: (ConnectionConfig) -> Void
    var onNewVM: (ConnectionSession) -> Void
    var onDeleteVM: (ConnectionSession, DomainSummary) -> Void
    var onCloneVM: (ConnectionSession, DomainSummary) -> Void

    var body: some View {
        List(selection: $selection) {
            ForEach(appState.sessions) { session in
                SessionSection(session: session, selection: $selection, onEdit: onEdit,
                               onNewVM: onNewVM, onDeleteVM: onDeleteVM, onCloneVM: onCloneVM)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Virtual Machines")
        .toolbar {
            // One unambiguous "+" menu with labeled actions, instead of two
            // near-identical icon buttons.
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
    @Binding var selection: DomainSelection?
    var onEdit: (ConnectionConfig) -> Void
    var onNewVM: (ConnectionSession) -> Void
    var onDeleteVM: (ConnectionSession, DomainSummary) -> Void
    var onCloneVM: (ConnectionSession, DomainSummary) -> Void

    var body: some View {
        Section {
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
            case .connected:
                if session.domains.isEmpty {
                    Text("No VMs").foregroundStyle(.secondary)
                } else {
                    ForEach(session.domains) { domain in
                        DomainRow(domain: domain, stats: session.stats[domain.uuid])
                            .tag(DomainSelection(sessionID: session.id, uuid: domain.uuid))
                            .contextMenu {
                                if domain.isActive {
                                    Button("Clone (requires shut off)") {}.disabled(true)
                                } else {
                                    Button("Clone \(domain.name)…") { onCloneVM(session, domain) }
                                }
                                Divider()
                                Button("Delete \(domain.name)…", role: .destructive) {
                                    onDeleteVM(session, domain)
                                }
                            }
                    }
                }
            }
        } header: {
            HStack(spacing: 8) {
                Text(session.config.name)
                Spacer()
                statusDot
                // Visible entry point for per-connection actions (the same menu
                // as right-click, which is otherwise undiscoverable on a header).
                Menu { contextMenu } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
                .padding(.trailing, 4)
            }
        }
        .contextMenu { contextMenu }
    }

    @ViewBuilder private var statusDot: some View {
        switch session.status {
        case .connected:
            Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.green)
        case .connecting:
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

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: domain.state.symbol)
                .foregroundStyle(domain.state.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(domain.name)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        guard domain.isActive, let s = stats else { return domain.state.label }
        return String(format: "%@ · %.0f%% · %@", domain.state.label,
                      s.cpuPercent, Format.memory(kiB: s.memUsedKiB))
    }
}
