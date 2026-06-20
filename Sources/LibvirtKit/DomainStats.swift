import CLibvirt
import Foundation

/// Per-disk cumulative block counters from `block.N.*` stats.
public struct BlockDeviceStats: Sendable, Equatable {
    public let index: Int
    public let name: String
    public let readBytes: UInt64
    public let writeBytes: UInt64
}

/// Per-NIC cumulative network counters from `net.N.*` stats.
public struct NetDeviceStats: Sendable, Equatable {
    public let index: Int
    public let name: String
    public let rxBytes: UInt64
    public let txBytes: UInt64
}

/// One poll's worth of runtime counters for a domain.
public struct DomainStats: Sendable {
    public let cpuTimeNs: UInt64          // cumulative guest CPU time
    public let balloonCurrentKiB: UInt64  // memory given to the guest
    public let balloonRSSKiB: UInt64      // resident set on the host
    public let vcpuCount: Int
    public let blockReadBytes: UInt64       // cumulative read bytes (all disks)
    public let blockWriteBytes: UInt64      // cumulative write bytes (all disks)
    public let netRxBytes: UInt64           // cumulative NIC receive bytes
    public let netTxBytes: UInt64           // cumulative NIC transmit bytes
    public let blockDevices: [BlockDeviceStats]
    public let netDevices: [NetDeviceStats]
}

/// Whether the QEMU guest agent is reachable for a running VM.
public enum GuestAgentStatus: Sendable, Equatable {
    case inactive
    case connected
    case unavailable

    public var label: String {
        switch self {
        case .inactive: return "VM not running"
        case .connected: return "Connected"
        case .unavailable: return "Not running"
        }
    }

    public var symbol: String {
        switch self {
        case .inactive: return "circle"
        case .connected: return "checkmark.circle.fill"
        case .unavailable: return "exclamationmark.circle"
        }
    }
}

/// A guest NIC with its addresses ("192.168.1.10/24").
public struct IfaceAddr: Sendable, Identifiable, Equatable {
    public let name: String
    public let mac: String?
    public let addresses: [String]
    public var id: String { name }
}

extension LibvirtConnection {
    /// Bulk runtime stats for all active domains (one round-trip).
    public func allDomainStats() async throws -> [String: DomainStats] {
        try await run { conn in
            var records: UnsafeMutablePointer<virDomainStatsRecordPtr?>?
            let want = UInt32(VIR_DOMAIN_STATS_CPU_TOTAL.rawValue
                            | VIR_DOMAIN_STATS_BALLOON.rawValue
                            | VIR_DOMAIN_STATS_VCPU.rawValue
                            | VIR_DOMAIN_STATS_BLOCK.rawValue
                            | VIR_DOMAIN_STATS_INTERFACE.rawValue)
            let n = virConnectGetAllDomainStats(conn, want, &records, 0)
            guard n >= 0, let records else {
                throw LibvirtError.lastError(fallback: "Failed to fetch domain stats")
            }
            defer { virDomainStatsRecordListFree(records) }

            var out: [String: DomainStats] = [:]
            for i in 0..<Int(n) {
                guard let rec = records[i] else { continue }
                var uuidBuf = [CChar](repeating: 0, count: Int(VIR_UUID_STRING_BUFLEN))
                guard virDomainGetUUIDString(rec.pointee.dom, &uuidBuf) == 0 else { continue }
                let uuid = String(cString: &uuidBuf)

                var cpuTime: UInt64 = 0, current: UInt64 = 0, rss: UInt64 = 0, vcpus = 0
                var blockAccum: [Int: (name: String?, rd: UInt64, wr: UInt64)] = [:]
                var netAccum: [Int: (name: String?, rx: UInt64, tx: UInt64)] = [:]
                for j in 0..<Int(rec.pointee.nparams) {
                    let p = rec.pointee.params[j]
                    let name = Self.paramName(p)
                    switch name {
                    case "cpu.time":        cpuTime = Self.paramUInt64(p) ?? 0
                    case "balloon.current": current = Self.paramUInt64(p) ?? 0
                    case "balloon.rss":     rss = Self.paramUInt64(p) ?? 0
                    case "vcpu.current":    vcpus = Int(Self.paramUInt64(p) ?? 0)
                    default:
                        if let (idx, suffix) = Self.indexedSuffix(name, prefix: "block.") {
                            var slot = blockAccum[idx] ?? (nil, 0, 0)
                            switch suffix {
                            case "name": slot.name = Self.paramString(p)
                            case "rd.bytes": slot.rd = Self.paramUInt64(p) ?? 0
                            case "wr.bytes": slot.wr = Self.paramUInt64(p) ?? 0
                            default: break
                            }
                            blockAccum[idx] = slot
                        } else if let (idx, suffix) = Self.indexedSuffix(name, prefix: "net.") {
                            var slot = netAccum[idx] ?? (nil, 0, 0)
                            switch suffix {
                            case "name": slot.name = Self.paramString(p)
                            case "rx.bytes": slot.rx = Self.paramUInt64(p) ?? 0
                            case "tx.bytes": slot.tx = Self.paramUInt64(p) ?? 0
                            default: break
                            }
                            netAccum[idx] = slot
                        }
                    }
                }
                let blocks = blockAccum.keys.sorted().map { idx in
                    let b = blockAccum[idx]!
                    return BlockDeviceStats(index: idx,
                                            name: b.name ?? "disk \(idx)",
                                            readBytes: b.rd, writeBytes: b.wr)
                }
                let nets = netAccum.keys.sorted().map { idx in
                    let n = netAccum[idx]!
                    return NetDeviceStats(index: idx,
                                          name: n.name ?? "nic \(idx)",
                                          rxBytes: n.rx, txBytes: n.tx)
                }
                let rdBytes = blocks.reduce(0) { $0 + $1.readBytes }
                let wrBytes = blocks.reduce(0) { $0 + $1.writeBytes }
                let rxBytes = nets.reduce(0) { $0 + $1.rxBytes }
                let txBytes = nets.reduce(0) { $0 + $1.txBytes }
                out[uuid] = DomainStats(cpuTimeNs: cpuTime, balloonCurrentKiB: current,
                                        balloonRSSKiB: rss, vcpuCount: vcpus,
                                        blockReadBytes: rdBytes, blockWriteBytes: wrBytes,
                                        netRxBytes: rxBytes, netTxBytes: txBytes,
                                        blockDevices: blocks, netDevices: nets)
            }
            return out
        }
    }

    /// Probes the QEMU guest agent (agent-only — no DHCP lease fallback).
    public func guestAgentStatus(uuid: String) async throws -> GuestAgentStatus {
        try await run { conn in
            try Self.withDomain(conn, uuid: uuid) { dom in
                var state: Int32 = 0
                _ = virDomainGetState(dom, &state, nil, 0)
                guard state == VIR_DOMAIN_RUNNING.rawValue || state == VIR_DOMAIN_PAUSED.rawValue else {
                    return .inactive
                }
                var ifaces: UnsafeMutablePointer<virDomainInterfacePtr?>?
                let n = virDomainInterfaceAddresses(
                    dom, &ifaces, UInt32(VIR_DOMAIN_INTERFACE_ADDRESSES_SRC_AGENT.rawValue), 0)
                if n >= 0 {
                    if let ifaces {
                        for i in 0..<Int(n) { virDomainInterfaceFree(ifaces[i]) }
                        free(ifaces)
                    }
                    return .connected
                }
                virResetLastError()
                return .unavailable
            }
        }
    }

    /// The guest's interfaces + IPs: guest agent when available (accurate,
    /// includes static addresses), DHCP leases as the fallback.
    public func interfaceAddresses(uuid: String) async throws -> [IfaceAddr] {
        try await run { conn in
            try Self.withDomain(conn, uuid: uuid) { dom in
                var ifaces: UnsafeMutablePointer<virDomainInterfacePtr?>?
                var n = virDomainInterfaceAddresses(
                    dom, &ifaces, UInt32(VIR_DOMAIN_INTERFACE_ADDRESSES_SRC_AGENT.rawValue), 0)
                if n < 0 {
                    virResetLastError()
                    n = virDomainInterfaceAddresses(
                        dom, &ifaces, UInt32(VIR_DOMAIN_INTERFACE_ADDRESSES_SRC_LEASE.rawValue), 0)
                }
                guard n >= 0, let ifaces else { return [] }
                defer {
                    for i in 0..<Int(n) { virDomainInterfaceFree(ifaces[i]) }
                    free(ifaces)
                }
                var out: [IfaceAddr] = []
                for i in 0..<Int(n) {
                    guard let ifp = ifaces[i] else { continue }
                    let name = String(cString: ifp.pointee.name)
                    if name == "lo" { continue }
                    let mac = ifp.pointee.hwaddr.map { String(cString: $0) }
                    var addrs: [String] = []
                    for j in 0..<Int(ifp.pointee.naddrs) {
                        let a = ifp.pointee.addrs[j]
                        guard let s = a.addr else { continue }
                        let addr = String(cString: s)
                        if addr.hasPrefix("127.") || addr == "::1" { continue }
                        addrs.append("\(addr)/\(a.prefix)")
                    }
                    if !addrs.isEmpty {
                        out.append(IfaceAddr(name: name, mac: mac, addresses: addrs))
                    }
                }
                return out
            }
        }
    }

    // MARK: - virTypedParameter helpers

    private static func paramName(_ p: virTypedParameter) -> String {
        withUnsafeBytes(of: p.field) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    private static func paramUInt64(_ p: virTypedParameter) -> UInt64? {
        switch UInt32(p.type) {
        case VIR_TYPED_PARAM_ULLONG.rawValue: return p.value.ul
        case VIR_TYPED_PARAM_LLONG.rawValue:  return p.value.l >= 0 ? UInt64(p.value.l) : nil
        case VIR_TYPED_PARAM_UINT.rawValue:   return UInt64(p.value.ui)
        case VIR_TYPED_PARAM_INT.rawValue:    return p.value.i >= 0 ? UInt64(p.value.i) : nil
        default: return nil
        }
    }

    private static func paramString(_ p: virTypedParameter) -> String? {
        guard UInt32(p.type) == VIR_TYPED_PARAM_STRING.rawValue, let s = p.value.s else { return nil }
        return String(cString: s)
    }

    /// Parses `prefix` + index + `.` + suffix, e.g. `block.2.rd.bytes` → (2, "rd.bytes").
    private static func indexedSuffix(_ name: String, prefix: String) -> (Int, String)? {
        guard name.hasPrefix(prefix) else { return nil }
        let rest = name.dropFirst(prefix.count)
        guard let dot = rest.firstIndex(of: ".") else { return nil }
        guard let idx = Int(rest[..<dot]) else { return nil }
        return (idx, String(rest[rest.index(after: dot)...]))
    }
}
