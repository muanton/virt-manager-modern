import CLibvirt
import Foundation

/// One poll's worth of runtime counters for a domain.
public struct DomainStats: Sendable {
    public let cpuTimeNs: UInt64          // cumulative guest CPU time
    public let balloonCurrentKiB: UInt64  // memory given to the guest
    public let balloonRSSKiB: UInt64      // resident set on the host
    public let vcpuCount: Int
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
                            | VIR_DOMAIN_STATS_VCPU.rawValue)
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
                let uuid = String(cString: uuidBuf)

                var cpuTime: UInt64 = 0, current: UInt64 = 0, rss: UInt64 = 0, vcpus = 0
                for j in 0..<Int(rec.pointee.nparams) {
                    let p = rec.pointee.params[j]
                    switch Self.paramName(p) {
                    case "cpu.time":        cpuTime = Self.paramUInt64(p) ?? 0
                    case "balloon.current": current = Self.paramUInt64(p) ?? 0
                    case "balloon.rss":     rss = Self.paramUInt64(p) ?? 0
                    case "vcpu.current":    vcpus = Int(Self.paramUInt64(p) ?? 0)
                    default: break
                    }
                }
                out[uuid] = DomainStats(cpuTimeNs: cpuTime, balloonCurrentKiB: current,
                                        balloonRSSKiB: rss, vcpuCount: vcpus)
            }
            return out
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
}
