import CLibvirt
import Foundation

public struct HostNodeInfo: Sendable, Hashable {
    public let model: String
    public let memoryKiB: UInt64
    public let cpus: UInt
    public let mhz: UInt
    public let sockets: UInt
    public let cores: UInt
    public let threads: UInt
}

public struct HostSummary: Sendable, Hashable {
    public let hostname: String?
    public let libvirtVersion: String
    public let node: HostNodeInfo
    public let domainCount: Int
    public let runningCount: Int
}

extension LibvirtConnection {
    /// Libvirt daemon version reported by the connected host.
    public func libvirtVersion() async throws -> String {
        try await run { conn in
            var version: UInt = 0
            guard virConnectGetLibVersion(conn, &version) == 0 else {
                throw LibvirtError.lastError(fallback: "Failed to read libvirt version")
            }
            let major = version / 1_000_000
            let minor = (version % 1_000_000) / 1_000
            let release = version % 1_000
            return "\(major).\(minor).\(release)"
        }
    }

    public func nodeInfo() async throws -> HostNodeInfo {
        try await run { conn in
            var info = virNodeInfo()
            guard virNodeGetInfo(conn, &info) == 0 else {
                throw LibvirtError.lastError(fallback: "Failed to read host information")
            }
            let model = withUnsafeBytes(of: info.model) { raw in
                let bytes = raw.bindMemory(to: CChar.self)
                return String(cString: bytes.baseAddress!)
            }
            return HostNodeInfo(
                model: model.trimmingCharacters(in: .controlCharacters),
                memoryKiB: UInt64(info.memory),
                cpus: UInt(info.cpus),
                mhz: UInt(info.mhz),
                sockets: UInt(info.sockets),
                cores: UInt(info.cores),
                threads: UInt(info.threads))
        }
    }

    public func hostSummary() async throws -> HostSummary {
        async let host = hostname()
        async let version = libvirtVersion()
        async let node = nodeInfo()
        async let domains = listDomains()
        let all = try await domains
        return HostSummary(
            hostname: await host,
            libvirtVersion: try await version,
            node: try await node,
            domainCount: all.count,
            runningCount: all.filter(\.isActive).count)
    }
}