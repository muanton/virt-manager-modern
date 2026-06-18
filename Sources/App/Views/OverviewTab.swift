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