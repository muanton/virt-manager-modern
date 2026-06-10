import CLibvirt
import Foundation

extension LibvirtConnection {
    /// Uploads a local file into a storage pool as a new (raw) volume — used
    /// for ISOs. Runs on its own queue so the main libvirt queue (polling,
    /// lifecycle) isn't blocked for the duration; virConnect is thread-safe.
    /// `progress` is called with 0…1 off the main thread.
    public func uploadVolume(pool poolName: String, name: String, localURL: URL,
                             progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        let conn = rawConnectionForStreaming()
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                do {
                    cont.resume(returning: try Self.doUpload(
                        conn: conn, poolName: poolName, name: name,
                        localURL: localURL, progress: progress))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private static func doUpload(conn: OpaquePointer, poolName: String, name: String,
                                 localURL: URL,
                                 progress: @Sendable (Double) -> Void) throws -> String {
        let attrs = try FileManager.default.attributesOfItem(atPath: localURL.path)
        guard let size = (attrs[.size] as? NSNumber)?.uint64Value, size > 0 else {
            throw LibvirtError(message: "Cannot read \(localURL.path)")
        }

        guard let pool = virStoragePoolLookupByName(conn, poolName) else {
            throw LibvirtError.lastError(fallback: "Storage pool \(poolName) not found")
        }
        defer { virStoragePoolFree(pool) }

        let volXML = """
        <volume>
          <name>\(xmlEscape(name))</name>
          <capacity>\(size)</capacity>
          <target><format type='raw'/></target>
        </volume>
        """
        guard let vol = virStorageVolCreateXML(pool, volXML, 0) else {
            throw LibvirtError.lastError(fallback: "Failed to create volume \(name)")
        }
        defer { virStorageVolFree(vol) }

        guard let stream = virStreamNew(conn, 0) else {
            virStorageVolDelete(vol, 0)
            throw LibvirtError.lastError(fallback: "Failed to open stream")
        }
        defer { virStreamFree(stream) }

        guard virStorageVolUpload(vol, stream, 0, size, 0) == 0 else {
            virStorageVolDelete(vol, 0)
            throw LibvirtError.lastError(fallback: "Failed to start upload")
        }

        do {
            let file = try FileHandle(forReadingFrom: localURL)
            defer { try? file.close() }
            var sent: UInt64 = 0
            while true {
                guard let chunk = try file.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
                try chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    var off = 0
                    while off < raw.count {
                        let n = virStreamSend(stream, raw.baseAddress!.advanced(by: off)
                            .assumingMemoryBound(to: CChar.self), raw.count - off)
                        if n < 0 {
                            throw LibvirtError.lastError(fallback: "Upload stream failed")
                        }
                        off += Int(n)
                    }
                }
                sent += UInt64(chunk.count)
                progress(Double(sent) / Double(size))
            }
            guard virStreamFinish(stream) == 0 else {
                throw LibvirtError.lastError(fallback: "Upload didn't complete")
            }
        } catch {
            virStreamAbort(stream)
            virStorageVolDelete(vol, 0)
            throw error
        }

        guard let p = virStorageVolGetPath(vol) else {
            throw LibvirtError.lastError(fallback: "Uploaded volume has no path")
        }
        defer { free(p) }
        return String(cString: p)
    }
}
