import CLibvirt
import Foundation

/// Lifecycle events surfaced from libvirt's domain callback.
public enum DomainLifecycleEvent: Int32, Sendable {
    case defined = 0
    case undefined = 1
    case started = 2
    case suspended = 3
    case resumed = 4
    case stopped = 5
    case shutdown = 6
    case pmSuspended = 7
    case crashed = 8
}

/// Runs libvirt's default event loop on one background thread for the process.
final class LibvirtEventLoop: @unchecked Sendable {
    static let shared = LibvirtEventLoop()

    private let lock = NSLock()
    private var thread: Thread?

    func ensureStarted() {
        lock.lock()
        defer { lock.unlock() }
        guard thread == nil else { return }
        _ = virEventRegisterDefaultImpl()
        let t = Thread {
            while !Thread.current.isCancelled {
                if virEventRunDefaultImpl() < 0 { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        t.name = "libvirt-events"
        t.start()
        thread = t
    }
}

private final class DomainEventHandler: @unchecked Sendable {
    let onEvent: @Sendable (DomainLifecycleEvent, DomainSummary?) -> Void

    init(onEvent: @escaping @Sendable (DomainLifecycleEvent, DomainSummary?) -> Void) {
        self.onEvent = onEvent
    }
}

private final class DomainEventRegistration: @unchecked Sendable {
    let conn: OpaquePointer
    let retained: Unmanaged<DomainEventHandler>

    init(conn: OpaquePointer, retained: Unmanaged<DomainEventHandler>) {
        self.conn = conn
        self.retained = retained
    }

    func deregister() {
        virConnectDomainEventDeregister(conn, domainEventCallback)
        retained.release()
    }
}

private func domainEventCallback(
    _ conn: OpaquePointer?,
    _ dom: OpaquePointer?,
    _ event: Int32,
    _ detail: Int32,
    _ opaque: UnsafeMutableRawPointer?
) -> Int32 {
    guard let opaque else { return 0 }
    let handler = Unmanaged<DomainEventHandler>.fromOpaque(opaque).takeUnretainedValue()
    let kind = DomainLifecycleEvent(rawValue: event) ?? .stopped
    let summary = dom.map { LibvirtConnection.domainSummary(from: $0) }
    handler.onEvent(kind, summary)
    return 0
}

extension LibvirtConnection {
    /// Registers a lifecycle callback. `onEvent` runs on libvirt's event thread.
    public func registerDomainEvents(
        onEvent: @escaping @Sendable (DomainLifecycleEvent, DomainSummary?) -> Void
    ) async throws -> @Sendable () -> Void {
        LibvirtEventLoop.shared.ensureStarted()
        let handler = DomainEventHandler(onEvent: onEvent)
        let retained = Unmanaged.passRetained(handler)

        return try await run { conn in
            let reg = virConnectDomainEventRegister(
                conn, domainEventCallback, retained.toOpaque(), nil)
            guard reg >= 0 else {
                retained.release()
                throw LibvirtError.lastError(fallback: "Failed to register domain events")
            }
            let registration = DomainEventRegistration(conn: conn, retained: retained)
            return { registration.deregister() }
        }
    }
}