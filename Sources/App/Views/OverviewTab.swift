import SwiftUI
import LibvirtKit

struct OverviewTab: View {
    @ObservedObject var session: ConnectionSession
    let domain: DomainSummary

    @State private var ifaces: [IfaceAddr] = []
    @State private var agentStatus: GuestAgentStatus = .inactive
    @State private var ifacesLoaded = false
    @State private var hasManagedSave = false

    var body: some View {
        Form {
            Section("Status") {
                LabeledContent("State") {
                    HStack(spacing: 6) {
                        Image(systemName: domain.state.symbol)
                            .foregroundStyle(domain.state.color)
                        Text(domain.state.label)
                    }
                }
                if !domain.isActive, hasManagedSave {
                    LabeledContent("Saved state") {
                        Label("On disk — Start restores memory", systemImage: "square.and.arrow.down")
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Domain ID", value: domain.domainID >= 0 ? "\(domain.domainID)" : "—")
                if domain.isActive {
                    LabeledContent("QEMU guest agent") {
                        HStack(spacing: 6) {
                            if !ifacesLoaded {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: agentStatus.symbol)
                                    .foregroundStyle(agentColor)
                                Text(agentStatus.label)
                            }
                        }
                    }
                }
            }
            if domain.isActive, let s = session.stats[domain.uuid] {
                Section("Usage") {
                    LabeledContent("CPU") {
                        HStack(spacing: 8) {
                            ProgressView(value: s.cpuPercent, total: 100).frame(width: 160)
                            Text(String(format: "%.0f%%", s.cpuPercent))
                                .monospacedDigit().frame(width: 44, alignment: .trailing)
                        }
                    }
                    LabeledContent("Memory") {
                        HStack(spacing: 8) {
                            ProgressView(value: Double(min(s.memUsedKiB, s.memTotalKiB)),
                                         total: Double(max(s.memTotalKiB, 1))).frame(width: 160)
                            Text("\(Format.memory(kiB: s.memUsedKiB)) of \(Format.memory(kiB: s.memTotalKiB))")
                                .monospacedDigit()
                        }
                    }
                }
            }
            if domain.isActive {
                Section("Network") {
                    if !ifacesLoaded {
                        ProgressView().controlSize(.small)
                    } else if ifaces.isEmpty {
                        Text(agentStatus == .connected
                             ? "Guest agent is running but reported no addresses."
                             : "No addresses reported (guest agent not running, no DHCP lease).")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(ifaces) { iface in
                            LabeledContent(iface.name) {
                                VStack(alignment: .trailing, spacing: 2) {
                                    ForEach(iface.addresses, id: \.self) { addr in
                                        HStack(spacing: 6) {
                                            Text(addr).monospaced().textSelection(.enabled)
                                            Button {
                                                let ip = String(addr.split(separator: "/")[0])
                                                NSPasteboard.general.clearContents()
                                                NSPasteboard.general.setString(ip, forType: .string)
                                            } label: { Image(systemName: "doc.on.doc") }
                                                .buttonStyle(.plain).foregroundStyle(.secondary)
                                                .help("Copy IP address")
                                        }
                                    }
                                    if let mac = iface.mac {
                                        Text(mac).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            Section("Hardware") {
                LabeledContent("vCPUs", value: "\(domain.vcpus)")
                LabeledContent("Memory", value: Format.memory(kiB: domain.memoryKiB))
                LabeledContent("Max Memory", value: Format.memory(kiB: domain.maxMemoryKiB))
            }
            Section("Identity") {
                LabeledContent("Name", value: domain.name)
                LabeledContent("UUID", value: domain.uuid)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .task(id: "\(domain.uuid)-\(domain.state.rawValue)") {
            hasManagedSave = (try? await session.hasManagedSave(uuid: domain.uuid)) ?? false
            ifacesLoaded = false
            while !Task.isCancelled {
                guard domain.isActive else {
                    ifaces = []
                    agentStatus = .inactive
                    ifacesLoaded = true
                    return
                }
                agentStatus = (try? await session.guestAgentStatus(uuid: domain.uuid)) ?? .unavailable
                ifaces = (try? await session.interfaceAddresses(uuid: domain.uuid)) ?? []
                ifacesLoaded = true
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private var agentColor: Color {
        switch agentStatus {
        case .connected: return .green
        case .unavailable: return .orange
        case .inactive: return .secondary
        }
    }
}