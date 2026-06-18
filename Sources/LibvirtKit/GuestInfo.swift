import CLibvirt
import Foundation

/// A guest filesystem mount reported by the QEMU guest agent.
public struct GuestMount: Sendable, Identifiable, Equatable {
    public let name: String
    public let mountpoint: String
    public let fstype: String
    public let totalBytes: UInt64
    public let usedBytes: UInt64

    public var id: String { mountpoint }

    public var usedFraction: Double {
        totalBytes > 0 ? min(1, Double(usedBytes) / Double(totalBytes)) : 0
    }
}

/// Hostname, OS, and mount information from `virDomainGetGuestInfo`.
public struct GuestInfo: Sendable, Equatable {
    public let hostname: String?
    public let osLabel: String?
    public let mounts: [GuestMount]

    public var isEmpty: Bool {
        hostname == nil && osLabel == nil && mounts.isEmpty
    }
}

extension LibvirtConnection {
    /// Guest agent details: hostname, OS pretty-name, and filesystem usage.
    public func guestInfo(uuid: String) async throws -> GuestInfo {
        try await run { conn in
            try Self.withDomain(conn, uuid: uuid) { dom in
                var state: Int32 = 0
                _ = virDomainGetState(dom, &state, nil, 0)
                guard state == VIR_DOMAIN_RUNNING.rawValue || state == VIR_DOMAIN_PAUSED.rawValue else {
                    return GuestInfo(hostname: nil, osLabel: nil, mounts: [])
                }

                var params: UnsafeMutablePointer<virTypedParameter>?
                var nparams: Int32 = 0
                // types=0: gather all supported info; unsupported agent commands are ignored.
                guard virDomainGetGuestInfo(dom, 0, &params, &nparams, 0) >= 0,
                      let params else {
                    throw LibvirtError.lastError(fallback: "Guest agent not available")
                }
                defer { virTypedParamsFree(params, nparams) }

                let hostname = Self.typedString(params, nparams, VIR_DOMAIN_GUEST_INFO_HOSTNAME_HOSTNAME)
                let osLabel = Self.parseOSLabel(params, nparams)
                let mounts = Self.parseMounts(params, nparams)
                return GuestInfo(hostname: hostname, osLabel: osLabel, mounts: mounts)
            }
        }
    }

    // MARK: - virTypedParameter parsing

    private static func typedString(
        _ params: UnsafeMutablePointer<virTypedParameter>, _ nparams: Int32, _ name: UnsafePointer<CChar>
    ) -> String? {
        var ptr: UnsafePointer<CChar>?
        guard virTypedParamsGetString(params, nparams, name, &ptr) == 1, let ptr else { return nil }
        let s = String(cString: ptr)
        return s.isEmpty ? nil : s
    }

    private static func typedULLong(
        _ params: UnsafeMutablePointer<virTypedParameter>, _ nparams: Int32, _ name: UnsafePointer<CChar>
    ) -> UInt64? {
        var value: UInt64 = 0
        guard virTypedParamsGetULLong(params, nparams, name, &value) == 1 else { return nil }
        return value
    }

    private static func parseOSLabel(
        _ params: UnsafeMutablePointer<virTypedParameter>, _ nparams: Int32
    ) -> String? {
        if let pretty = typedString(params, nparams, VIR_DOMAIN_GUEST_INFO_OS_PRETTY_NAME) {
            return pretty
        }
        let name = typedString(params, nparams, VIR_DOMAIN_GUEST_INFO_OS_NAME)
        let version = typedString(params, nparams, VIR_DOMAIN_GUEST_INFO_OS_VERSION)
        switch (name, version) {
        case let (n?, v?): return "\(n) \(v)"
        case let (n?, nil): return n
        case let (nil, v?): return v
        default: return nil
        }
    }

    private static func parseMounts(
        _ params: UnsafeMutablePointer<virTypedParameter>, _ nparams: Int32
    ) -> [GuestMount] {
        var count: UInt32 = 0
        guard virTypedParamsGetUInt(params, nparams, VIR_DOMAIN_GUEST_INFO_FS_COUNT, &count) == 1 else {
            return []
        }

        var mounts: [GuestMount] = []
        mounts.reserveCapacity(Int(count))
        for i in 0..<Int(count) {
            let mpKey = "fs.\(i).mountpoint"
            let nameKey = "fs.\(i).name"
            let typeKey = "fs.\(i).fstype"
            let totalKey = "fs.\(i).total-bytes"
            let usedKey = "fs.\(i).used-bytes"

            guard let mountpoint = mpKey.withCString({ typedString(params, nparams, $0) }) else {
                continue
            }
            let name = nameKey.withCString { typedString(params, nparams, $0) } ?? mountpoint
            let fstype = typeKey.withCString { typedString(params, nparams, $0) } ?? "?"
            let total = totalKey.withCString { typedULLong(params, nparams, $0) } ?? 0
            let used = usedKey.withCString { typedULLong(params, nparams, $0) } ?? 0
            mounts.append(GuestMount(name: name, mountpoint: mountpoint, fstype: fstype,
                                     totalBytes: total, usedBytes: used))
        }

        return mounts
            .filter { $0.totalBytes > 0 }
            .sorted { $0.usedFraction > $1.usedFraction }
    }
}