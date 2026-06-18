import Foundation

/// A single human-readable difference between running and saved domain XML.
public struct DomainConfigChange: Identifiable, Sendable, Hashable {
    public let id = UUID()
    public let label: String
    public let liveValue: String
    public let savedValue: String
}

/// Compares live (running) and saved (persistent) libvirt domain definitions.
public enum DomainConfigDiff {
    public static func changes(liveXML: String, savedXML: String) throws -> [DomainConfigChange] {
        let live = try DomainConfig(xml: liveXML)
        let saved = try DomainConfig(xml: savedXML)
        var out: [DomainConfigChange] = []

        if live.vcpu != saved.vcpu {
            out.append(.init(label: "vCPUs",
                             liveValue: String(live.vcpu),
                             savedValue: String(saved.vcpu)))
        }
        if live.memoryKiB != saved.memoryKiB {
            out.append(.init(label: "Maximum memory",
                             liveValue: formatKiB(live.memoryKiB),
                             savedValue: formatKiB(saved.memoryKiB)))
        }
        if live.currentMemoryKiB != saved.currentMemoryKiB {
            out.append(.init(label: "Current memory",
                             liveValue: formatKiB(live.currentMemoryKiB),
                             savedValue: formatKiB(saved.currentMemoryKiB)))
        }
        let liveBoot = live.bootDevices.joined(separator: ", ")
        let savedBoot = saved.bootDevices.joined(separator: ", ")
        if liveBoot != savedBoot {
            out.append(.init(label: "Boot order",
                             liveValue: liveBoot.isEmpty ? "—" : liveBoot,
                             savedValue: savedBoot.isEmpty ? "—" : savedBoot))
        }

        let liveDevices = live.deviceDiffSignatures()
        let savedDevices = saved.deviceDiffSignatures()
        for d in liveDevices.subtracting(savedDevices).sorted() {
            out.append(.init(label: "Device", liveValue: d, savedValue: "not in saved config"))
        }
        for d in savedDevices.subtracting(liveDevices).sorted() {
            out.append(.init(label: "Device", liveValue: "not running", savedValue: d))
        }
        return out
    }

    private static func formatKiB(_ kiB: UInt64) -> String {
        let mib = Double(kiB) / 1024
        if mib >= 1024 { return String(format: "%.1f GiB", mib / 1024) }
        if mib >= 1 { return String(format: "%.0f MiB", mib) }
        return "\(kiB) KiB"
    }
}