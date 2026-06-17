import SwiftUI
import LibvirtKit

struct NetworksSheet: View {
    @ObservedObject var session: ConnectionSession
    @Environment(\.dismiss) private var dismiss

    @State private var loaded = false
    @State private var working = false
    @State private var error: String?
    @State private var confirmDelete: VirtNetwork?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Networks on \(session.config.name)").font(.title2).bold()
                Spacer()
                Button { Task { await reload() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(working)
                Button("Add Default NAT…") { addDefault() }
                    .disabled(working)
            }
            .padding()

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.caption).padding(.horizontal)
            }

            if !loaded {
                Spacer()
                ProgressView().controlSize(.large).frame(maxWidth: .infinity)
                Spacer()
            } else if session.networks.isEmpty {
                ContentUnavailableView("No Networks", systemImage: "network",
                    description: Text("Define a virtual network to connect VMs to the host."))
            } else {
                List(session.networks) { net in
                    networkRow(net)
                }
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 560, height: 420)
        .task { await reload() }
        .confirmationDialog(
            "Delete network “\(confirmDelete?.name ?? "")”?",
            isPresented: Binding(get: { confirmDelete != nil },
                                 set: { if !$0 { confirmDelete = nil } }),
            titleVisibility: .visible, presenting: confirmDelete) { net in
            Button("Delete", role: .destructive) { deleteNetwork(net) }
        } message: { _ in
            Text("The network definition is removed from libvirt. Running VMs using it are unaffected until restarted.")
        }
    }

    private func networkRow(_ net: VirtNetwork) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(net.name).font(.headline)
                    statusBadge(net.active ? "active" : "inactive", net.active ? .green : .secondary)
                    if net.persistent {
                        statusBadge("persistent", .blue)
                    }
                }
                if let bridge = net.bridge {
                    Text("bridge \(bridge)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if net.active {
                Button("Stop") { setActive(net.name, false) }.disabled(working)
            } else if net.persistent {
                Button("Start") { setActive(net.name, true) }.disabled(working)
            }
            if net.persistent {
                Button(role: .destructive) { confirmDelete = net } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }

    private func statusBadge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.2)))
    }

    private func reload() async {
        working = true
        defer { working = false }
        do {
            try await session.loadNetworks()
            error = nil
        } catch let err {
            error = err.localizedDescription
        }
        loaded = true
    }

    private func setActive(_ name: String, _ active: Bool) {
        working = true
        Task {
            defer { working = false }
            do {
                try await session.setNetworkActive(name: name, active: active)
                error = nil
            } catch let err {
                error = err.localizedDescription
            }
        }
    }

    private func addDefault() {
        working = true
        Task {
            defer { working = false }
            do {
                try await session.defineNetwork(xml: LibvirtConnection.defaultNATNetworkXML)
                try await session.setNetworkActive(name: "default", active: true)
                error = nil
            } catch let err {
                error = err.localizedDescription
            }
        }
    }

    private func deleteNetwork(_ net: VirtNetwork) {
        working = true
        Task {
            defer { working = false }
            do {
                try await session.undefineNetwork(name: net.name)
                error = nil
            } catch let err {
                error = err.localizedDescription
            }
        }
    }
}