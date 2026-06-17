import CLibvirt
import Foundation

public enum StoragePoolLifecycleEvent: Int32, Sendable {
    case defined = 0
    case undefined = 1
    case started = 2
    case stopped = 3
    case created = 4
    case deleted = 5
}

private final class StoragePoolEventHandler: @unchecked Sendable {
    let onLifecycle: @Sendable (StoragePoolLifecycleEvent, String?) -> Void
    let onRefresh: @Sendable (String?) -> Void

    init(
        onLifecycle: @escaping @Sendable (StoragePoolLifecycleEvent, String?) -> Void,
        onRefresh: @escaping @Sendable (String?) -> Void
    ) {
        self.onLifecycle = onLifecycle
        self.onRefresh = onRefresh
    }
}

private final class StoragePoolEventRegistration: @unchecked Sendable {
    let conn: OpaquePointer
    let lifecycleID: Int32
    let refreshID: Int32
    let retained: Unmanaged<StoragePoolEventHandler>

    init(conn: OpaquePointer, lifecycleID: Int32, refreshID: Int32,
         retained: Unmanaged<StoragePoolEventHandler>) {
        self.conn = conn
        self.lifecycleID = lifecycleID
        self.refreshID = refreshID
        self.retained = retained
    }

    func deregister() {
        if lifecycleID >= 0 {
            virConnectStoragePoolEventDeregisterAny(conn, lifecycleID)
        }
        if refreshID >= 0 {
            virConnectStoragePoolEventDeregisterAny(conn, refreshID)
        }
        retained.release()
    }
}

private func poolName(_ pool: OpaquePointer?) -> String? {
    guard let pool else { return nil }
    return virStoragePoolGetName(pool).map { String(cString: $0) }
}

private let storagePoolLifecycleCallback: @convention(c) (
    OpaquePointer?, OpaquePointer?, Int32, Int32, UnsafeMutableRawPointer?
) -> Void = { conn, pool, event, detail, opaque in
    _ = conn; _ = detail
    guard let opaque else { return }
    let handler = Unmanaged<StoragePoolEventHandler>.fromOpaque(opaque).takeUnretainedValue()
    let kind = StoragePoolLifecycleEvent(rawValue: event) ?? .stopped
    handler.onLifecycle(kind, poolName(pool))
}

private let storagePoolRefreshCallback: @convention(c) (
    OpaquePointer?, OpaquePointer?, UnsafeMutableRawPointer?
) -> Void = { conn, pool, opaque in
    _ = conn
    guard let opaque else { return }
    let handler = Unmanaged<StoragePoolEventHandler>.fromOpaque(opaque).takeUnretainedValue()
    handler.onRefresh(poolName(pool))
}

extension LibvirtConnection {
    /// Registers storage-pool lifecycle and refresh callbacks.
    public func registerStoragePoolEvents(
        onLifecycle: @escaping @Sendable (StoragePoolLifecycleEvent, String?) -> Void,
        onRefresh: @escaping @Sendable (String?) -> Void
    ) async throws -> @Sendable () -> Void {
        LibvirtEventLoop.shared.ensureStarted()
        let handler = StoragePoolEventHandler(onLifecycle: onLifecycle, onRefresh: onRefresh)
        let retained = Unmanaged.passRetained(handler)

        return try await run { conn in
            let lifecycleFn = unsafeBitCast(
                storagePoolLifecycleCallback,
                to: virConnectStoragePoolEventGenericCallback.self)
            let lifecycleID = virConnectStoragePoolEventRegisterAny(
                conn, nil,
                Int32(VIR_STORAGE_POOL_EVENT_ID_LIFECYCLE.rawValue),
                lifecycleFn, retained.toOpaque(), nil)
            guard lifecycleID >= 0 else {
                retained.release()
                throw LibvirtError.lastError(fallback: "Failed to register storage pool lifecycle events")
            }

            let refreshID = virConnectStoragePoolEventRegisterAny(
                conn, nil,
                Int32(VIR_STORAGE_POOL_EVENT_ID_REFRESH.rawValue),
                storagePoolRefreshCallback, retained.toOpaque(), nil)
            guard refreshID >= 0 else {
                virConnectStoragePoolEventDeregisterAny(conn, lifecycleID)
                retained.release()
                throw LibvirtError.lastError(fallback: "Failed to register storage pool refresh events")
            }

            let registration = StoragePoolEventRegistration(
                conn: conn, lifecycleID: lifecycleID, refreshID: refreshID, retained: retained)
            return { registration.deregister() }
        }
    }
}