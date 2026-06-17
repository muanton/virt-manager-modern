import SwiftUI
import LibvirtKit

struct HostDashboardSheet: View {
    @ObservedObject var session: ConnectionSession
    @Environment(\.dismiss) private var dismiss

    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Host — \(session.config.name)").font(.title2).bold()
                Spacer()
                Button { Task { await reload() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
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
            } else if let host = session.hostSummary {
                Form {
                    Section("Connection") {
                        LabeledContent("Hostname", value: host.hostname ?? "—")
                        LabeledContent("Libvirt", value: host.libvirtVersion)
                        LabeledContent("Client library", value: Libvirt.libraryVersion())
                    }
                    Section("Virtual Machines") {
                        LabeledContent("Defined", value: "\(host.domainCount)")
                        LabeledContent("Running", value: "\(host.runningCount)")
                    }
                    Section("Hardware") {
                        LabeledContent("CPU model", value: host.node.model)
                        LabeledContent("Logical CPUs", value: "\(host.node.cpus)")
                        if host.node.mhz > 0 {
                            LabeledContent("CPU frequency", value: "\(host.node.mhz) MHz")
                        }
                        LabeledContent("Memory", value: Format.memory(kiB: host.node.memoryKiB))
                        if host.node.sockets > 1 || host.node.cores > 1 {
                            LabeledContent("Topology") {
                                Text("\(host.node.sockets) sockets × \(host.node.cores) cores"
                                     + (host.node.threads > 1 ? " × \(host.node.threads) threads" : ""))
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            } else {
                ContentUnavailableView("Host Unavailable", systemImage: "server.rack",
                    description: Text("Could not read host information."))
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 480, height: 420)
        .task { await reload() }
    }

    private func reload() async {
        await session.refreshHostSummary()
        if session.hostSummary == nil {
            error = "Failed to load host information."
        } else {
            error = nil
        }
        loaded = true
    }
}