import CLibvirt
import Foundation

/// A live serial/paravirt console attached to a domain's PTY over the libvirt
/// stream API. A dedicated thread does blocking receives (the stream rides the
/// existing qemu+ssh transport); writes are small and synchronous.
public final class SerialConsoleHandle: @unchecked Sendable {
    private let stream: OpaquePointer
    private var receiveThread: Thread?
    private let onData: @Sendable (Data) -> Void
    private let onClose: @Sendable (String?) -> Void
    private var closed = false
    private let lock = NSLock()

    init(stream: OpaquePointer,
         onData: @escaping @Sendable (Data) -> Void,
         onClose: @escaping @Sendable (String?) -> Void) {
        self.stream = stream
        self.onData = onData
        self.onClose = onClose
        let t = Thread { [weak self] in self?.receiveLoop() }
        t.name = "vmm-serial-console"
        t.start()
        receiveThread = t
    }

    private func receiveLoop() {
        var buf = [CChar](repeating: 0, count: 16 * 1024)
        while true {
            let n = virStreamRecv(stream, &buf, buf.count)
            if n > 0 {
                onData(Data(bytes: buf, count: Int(n)))
            } else if n == 0 {
                finish(error: nil)
                return
            } else {
                lock.lock(); let wasClosed = closed; lock.unlock()
                finish(error: wasClosed ? nil : LibvirtError.lastError(
                    fallback: "Console stream error").message)
                return
            }
        }
    }

    /// Only ever runs on the receive thread — the single owner of the free.
    private var finished = false
    private func finish(error: String?) {
        lock.lock()
        let alreadyFinished = finished
        finished = true
        lock.unlock()
        guard !alreadyFinished else { return }
        virStreamFree(stream)
        onClose(error)
    }

    /// Sends keystrokes to the guest.
    public func send(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var off = 0
            while off < raw.count {
                let n = virStreamSend(stream, raw.baseAddress!.advanced(by: off)
                    .assumingMemoryBound(to: CChar.self), raw.count - off)
                if n <= 0 { return }
                off += Int(n)
            }
        }
    }

    /// Aborts the stream; the blocked receive unblocks, and the receive
    /// thread (the stream's single owner) frees it and reports the close.
    public func close() {
        lock.lock()
        let wasClosed = closed
        closed = true
        lock.unlock()
        if !wasClosed { virStreamAbort(stream) }
    }

    deinit { close() }
}

extension LibvirtConnection {
    /// Opens the domain's primary console device (serial or paravirt).
    public func openSerialConsole(
        uuid: String,
        onData: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable (String?) -> Void
    ) async throws -> SerialConsoleHandle {
        return try await run { conn in
            try Self.withDomain(conn, uuid: uuid) { dom in
                guard let stream = virStreamNew(conn, 0) else {
                    throw LibvirtError.lastError(fallback: "Failed to create stream")
                }
                guard virDomainOpenConsole(dom, nil, stream,
                                           UInt32(VIR_DOMAIN_CONSOLE_FORCE.rawValue)) == 0 else {
                    virStreamFree(stream)
                    throw LibvirtError.lastError(fallback: "Failed to open the console")
                }
                return SerialConsoleHandle(stream: stream, onData: onData, onClose: onClose)
            }
        }
    }
}
