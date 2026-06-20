import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LibvirtKit

struct OverviewTab: View {
    @ObservedObject var session: ConnectionSession
    let domain: DomainSummary

    @State private var ifaces: [IfaceAddr] = []
    @State private var guestInfo: GuestInfo?
    @State private var agentStatus: GuestAgentStatus = .inactive
    @State private var guestLoaded = false
    @State private var ifacesLoaded = false
    @State private var hasManagedSave = false
    @State private var screenshotData: Data?
    @State private var screenshotError: String?
    @State private var screenshotLoading = false
    @State private var showAddForward = false
    @State private var addForwardIP: String?
    @State private var sshPrompt: IdentifiedIP?

    /// Identifiable wrapper so the SSH prompt can drive `.sheet(item:)`.
    struct IdentifiedIP: Identifiable { let id = UUID(); let ip: String }

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
                if session.hasConfigDrift(uuid: domain.uuid) {
                    LabeledContent("Configuration") {
                        Label("Running differs from saved", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help("Live changes may be lost on reboot. Open the Hardware tab to review or sync.")
                    }
                }
                if domain.isActive {
                    LabeledContent("QEMU guest agent") {
                        HStack(spacing: 6) {
                            if !guestLoaded {
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
            if domain.isActive {
                Section("Guest") {
                    if !guestLoaded {
                        ProgressView().controlSize(.small)
                    } else if let guestInfo, !guestInfo.isEmpty {
                        if let hostname = guestInfo.hostname {
                            LabeledContent("Hostname", value: hostname)
                                .textSelection(.enabled)
                        }
                        if let os = guestInfo.osLabel {
                            LabeledContent("Operating system", value: os)
                                .textSelection(.enabled)
                        }
                        if !guestInfo.mounts.isEmpty {
                            ForEach(guestInfo.mounts) { mount in
                                LabeledContent(mount.mountpoint) {
                                    VStack(alignment: .trailing, spacing: 4) {
                                        HStack(spacing: 8) {
                                            ProgressView(value: mount.usedFraction)
                                                .frame(width: 120)
                                            Text("\(Format.bytes(mount.usedBytes)) of \(Format.bytes(mount.totalBytes))")
                                                .monospacedDigit()
                                        }
                                        Text(mount.fstype)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    } else if agentStatus == .connected {
                        Text("Guest agent is connected but did not report hostname or disk usage.")
                            .foregroundStyle(.secondary)
                    } else if agentStatus == .unavailable {
                        Text("Install and start the QEMU guest agent in the VM to see hostname, OS, and disk usage.")
                            .foregroundStyle(.secondary)
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
                    PerDeviceIORow(title: "Disk I/O",
                                   totalRead: s.diskReadBps, totalWrite: s.diskWriteBps,
                                   devices: s.blockDevices)
                    PerDeviceIORow(title: "Network I/O",
                                   totalRead: s.netRxBps, totalWrite: s.netTxBps,
                                   devices: s.netDevices)
                }
            }
            if domain.isActive, let history = session.statHistory[domain.uuid] {
                Section("History (last 10 min)") {
                    if history.count >= 2 {
                        StatChart(title: "CPU", samples: history, yDomain: 0...100, tint: .blue,
                                  format: { String(format: "%.0f%%", $0) },
                                  value: { $0.cpuPercent })
                        StatChart(title: "Memory", samples: history, yDomain: memDomain(history),
                                  tint: .green,
                                  format: { Format.memory(kiB: UInt64(max(0, $0))) },
                                  value: { Double($0.memUsedKiB) })
                        DualStatChart(title: "Disk I/O", samples: history,
                                      series: [("Read", \.diskReadBps), ("Write", \.diskWriteBps)])
                        DualStatChart(title: "Network I/O", samples: history,
                                      series: [("Rx", \.netRxBps), ("Tx", \.netTxBps)])
                    } else {
                        Text("Collecting data…").foregroundStyle(.secondary).font(.caption)
                    }
                }
            }
            if domain.isActive {
                Section("Display") {
                    if screenshotLoading, screenshotData == nil {
                        ProgressView().controlSize(.small)
                    } else if let screenshotData {
                        ScreenshotPreview(data: screenshotData)
                        HStack {
                            Button("Refresh") { Task { await captureScreenshot() } }
                                .disabled(screenshotLoading)
                            Button("Save…") { saveScreenshot(screenshotData) }
                            Spacer()
                        }
                    } else if let screenshotError {
                        Text(screenshotError).foregroundStyle(.secondary).font(.caption)
                        Button("Retry") { Task { await captureScreenshot() } }
                    } else {
                        Button("Capture Screenshot") { Task { await captureScreenshot() } }
                    }
                }
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
                                            if session.config.sshHost != nil, let ip = ipv4(addr) {
                                                Button { sshPrompt = IdentifiedIP(ip: ip) } label: {
                                                    Image(systemName: "terminal")
                                                }
                                                .buttonStyle(.plain).foregroundStyle(.secondary)
                                                .help("SSH to guest")
                                                Button { addForwardIP = ip; showAddForward = true } label: {
                                                    Image(systemName: "arrow.right.arrow.left")
                                                }
                                                .buttonStyle(.plain).foregroundStyle(.secondary)
                                                .help("Forward a port from this guest")
                                            }
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
                if session.config.sshHost != nil {
                    Section("Port Forwarding") {
                        let forwards = session.portForwards.filter { $0.vmUUID == domain.uuid }
                        if forwards.isEmpty {
                            Text("Forward a guest TCP port to your Mac over SSH.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(forwards) { f in
                            PortForwardRow(forward: f) { session.removePortForward(id: f.id) }
                        }
                        Button {
                            addForwardIP = ifaces.flatMap { $0.addresses.compactMap(ipv4) }.first
                            showAddForward = true
                        } label: {
                            Label("Add forward…", systemImage: "plus")
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
        .sheet(isPresented: $showAddForward) {
            PortForwardSheet(ips: ipv4List, defaultIP: addForwardIP) { ip, port, label in
                Task { await session.addPortForward(uuid: domain.uuid, guestIP: ip,
                                                    guestPort: port, label: label) }
            }
        }
        .sheet(item: $sshPrompt) { prompt in
            SSHUserPrompt(guestIP: prompt.ip,
                          defaultUser: session.config.sshUser ?? NSUserName()) { user in
                guard let host = session.config.sshHost else { return }
                QuickConnect.openSSH(sshHost: host, sshUser: session.config.sshUser,
                                     sshPort: session.config.sshPort,
                                     guestUser: user, guestIP: prompt.ip)
            }
        }
        .task(id: "\(domain.uuid)-\(domain.state.rawValue)") {
            hasManagedSave = (try? await session.hasManagedSave(uuid: domain.uuid)) ?? false
            guestLoaded = false
            ifacesLoaded = false
            screenshotData = nil
            screenshotError = nil
            if domain.isActive { await captureScreenshot() }
            while !Task.isCancelled {
                guard domain.isActive else {
                    ifaces = []
                    guestInfo = nil
                    agentStatus = .inactive
                    screenshotData = nil
                    guestLoaded = true
                    ifacesLoaded = true
                    return
                }
                agentStatus = (try? await session.guestAgentStatus(uuid: domain.uuid)) ?? .unavailable
                guestInfo = try? await session.guestInfo(uuid: domain.uuid)
                guestLoaded = true
                ifaces = (try? await session.interfaceAddresses(uuid: domain.uuid)) ?? []
                ifacesLoaded = true
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .task(id: "screenshot-\(domain.uuid)") {
            guard domain.isActive else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await captureScreenshot()
            }
        }
    }

    private func captureScreenshot() async {
        guard domain.isActive else { return }
        screenshotLoading = true
        defer { screenshotLoading = false }
        do {
            let shot = try await session.screenshot(uuid: domain.uuid)
            screenshotData = shot.data
            screenshotError = nil
        } catch {
            screenshotError = error.localizedDescription
        }
    }

    private func saveScreenshot(_ data: Data) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(domain.name)-screenshot.png"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
    }

    private var agentColor: Color {
        switch agentStatus {
        case .connected: return .green
        case .unavailable: return .orange
        case .inactive: return .secondary
        }
    }

    /// Y-axis top for the memory chart: the largest of total/used seen in the
    /// window, so the area never clips when RSS briefly exceeds the balloon size.
    private func memDomain(_ history: [ConnectionSession.StatSample]) -> ClosedRange<Double> {
        let top = history.map { Double(max($0.memTotalKiB, $0.memUsedKiB)) }.max() ?? 1
        return 0...max(1, top)
    }

    /// The IPv4 address from an `addr/prefix` string, or nil for IPv6.
    private func ipv4(_ addr: String) -> String? {
        let ip = String(addr.split(separator: "/").first ?? "")
        return (ip.contains(".") && !ip.contains(":")) ? ip : nil
    }

    /// Distinct IPv4 addresses across all guest interfaces.
    private var ipv4List: [String] {
        var seen: [String] = []
        for iface in ifaces {
            for ip in iface.addresses.compactMap(ipv4) where !seen.contains(ip) {
                seen.append(ip)
            }
        }
        return seen
    }
}

/// One active (or failed) port forward, with copy / open-in-browser / stop.
private struct PortForwardRow: View {
    let forward: PortForward
    let onStop: () -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: 10) {
                switch forward.status {
                case .starting:
                    ProgressView().controlSize(.small)
                case .active:
                    Button { QuickConnect.copyLocalAddress(localPort: forward.localPort) } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Copy localhost:\(forward.localPort)")
                    Button { QuickConnect.openInBrowser(localPort: forward.localPort) } label: {
                        Image(systemName: "safari")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Open http://localhost:\(forward.localPort)")
                case .failed(let msg):
                    Text(msg).font(.caption).foregroundStyle(.red).lineLimit(1).help(msg)
                }
                Button(action: onStop) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Stop forward")
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(forward.isLive
                     ? "localhost:\(forward.localPort) → \(forward.guestIP):\(forward.guestPort)"
                     : "\(forward.guestIP):\(forward.guestPort)")
                    .monospaced().font(.callout)
                if !forward.label.isEmpty {
                    Text(forward.label).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Total I/O rate with an expandable per-device breakdown when multiple disks or NICs exist.
private struct PerDeviceIORow: View {
    let title: String
    let totalRead: UInt64
    let totalWrite: UInt64
    let devices: [ConnectionSession.DeviceIORates]

    var body: some View {
        LabeledContent(title) {
            if devices.count > 1 {
                DisclosureGroup {
                    ForEach(devices) { dev in
                        HStack {
                            Text(dev.label)
                            Spacer()
                            Text(ioRates(dev.readBps, dev.writeBps))
                                .monospacedDigit()
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } label: {
                    Text(ioRates(totalRead, totalWrite))
                        .monospacedDigit()
                }
            } else {
                Text(ioRates(totalRead, totalWrite))
                    .monospacedDigit()
            }
        }
    }

    private func ioRates(_ down: UInt64, _ up: UInt64) -> String {
        "↓ \(Format.rate(bytesPerSecond: down)) · ↑ \(Format.rate(bytesPerSecond: up))"
    }
}