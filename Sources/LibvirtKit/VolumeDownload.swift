import CLibvirt
import Foundation

extension LibvirtConnection {
    /// Downloads a storage volume to a local file over the libvirt stream API.
    public func downloadVolume(path: String, localURL: URL,
                               progress: @escaping @Sendable (Double) -> Void) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                do {
                    // Reach the raw handle through `self` (an @unchecked Sendable
                    // class) inside the closure rather than capturing the bare,
                    // non-Sendable OpaquePointer.
                    try Self.doDownload(conn: self.rawConnectionForStreaming(),
                                        path: path, localURL: localURL, progress: progress)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private static func doDownload(conn: OpaquePointer, path: String, localURL: URL,
                                   progress: @Sendable (Double) -> Void) throws {
        guard let vol = virStorageVolLookupByPath(conn, path) else {
            throw LibvirtError.lastError(fallback: "Volume not found: \(path)")
        }
        defer { virStorageVolFree(vol) }

        var info = virStorageVolInfo()
        guard virStorageVolGetInfo(vol, &info) == 0 else {
            throw LibvirtError.lastError(fallback: "Failed to read volume info")
        }
        let capacity = UInt64(info.capacity)

        guard let stream = virStreamNew(conn, 0) else {
            throw LibvirtError.lastError(fallback: "Failed to open stream")
        }
        defer { virStreamFree(stream) }

        guard virStorageVolDownload(vol, stream, 0, 0, 0) == 0 else {
            throw LibvirtError.lastError(fallback: "Failed to start download")
        }

        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        let file = try FileHandle(forWritingTo: localURL)
        defer { try? file.close() }

        var received: UInt64 = 0
        var buf = [CChar](repeating: 0, count: 1 << 20)
        do {
            while true {
                let n = virStreamRecv(stream, &buf, buf.count)
                if n > 0 {
                    let data = Data(bytes: buf, count: Int(n))
                    try file.write(contentsOf: data)
                    received += UInt64(n)
                    if capacity > 0 {
                        progress(min(1, Double(received) / Double(capacity)))
                    }
                } else if n == 0 {
                    break
                } else {
                    throw LibvirtError.lastError(fallback: "Download stream failed")
                }
            }
            guard virStreamFinish(stream) == 0 else {
                throw LibvirtError.lastError(fallback: "Download didn't complete")
            }
            progress(1)
        } catch {
            virStreamAbort(stream)
            try? FileManager.default.removeItem(at: localURL)
            throw error
        }
    }
}