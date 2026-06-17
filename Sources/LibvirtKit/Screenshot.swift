import CLibvirt
import Foundation

public struct DomainScreenshot: Sendable {
    public let data: Data
    public let mimeType: String
}

extension LibvirtConnection {
    /// Captures the running guest's display via libvirt (format is hypervisor-specific, usually PNG).
    public func screenshot(uuid: String, screen: UInt32 = 0) async throws -> DomainScreenshot {
        try await run { conn in
            try Self.withDomain(conn, uuid: uuid) { dom in
                guard let stream = virStreamNew(conn, 0) else {
                    throw LibvirtError.lastError(fallback: "Failed to open stream")
                }
                defer { virStreamFree(stream) }

                guard let mimeC = virDomainScreenshot(dom, stream, screen, 0) else {
                    throw LibvirtError.lastError(fallback: "Screenshot failed")
                }
                defer { free(mimeC) }
                let mime = String(cString: mimeC)

                var out = Data()
                let chunk = 65536
                var buffer = [UInt8](repeating: 0, count: chunk)
                while true {
                    let n = buffer.withUnsafeMutableBytes { raw -> Int32 in
                        guard let base = raw.baseAddress else { return -1 }
                        return virStreamRecv(stream, base.assumingMemoryBound(to: CChar.self), chunk)
                    }
                    if n < 0 {
                        virStreamAbort(stream)
                        throw LibvirtError.lastError(fallback: "Screenshot stream failed")
                    }
                    if n == 0 { break }
                    out.append(contentsOf: buffer.prefix(Int(n)))
                }
                guard virStreamFinish(stream) == 0 else {
                    throw LibvirtError.lastError(fallback: "Screenshot stream finish failed")
                }
                guard !out.isEmpty else {
                    throw LibvirtError(message: "Screenshot returned no data")
                }
                return DomainScreenshot(data: out, mimeType: mime)
            }
        }
    }
}