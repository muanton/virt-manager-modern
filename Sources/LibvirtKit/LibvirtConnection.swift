import CLibvirt
import Foundation

/// A connection to a libvirt daemon (local `test:///` or remote `qemu+ssh://`).
///
/// All libvirt calls are blocking (opening a `qemu+ssh` connection spawns `ssh`
/// and can take seconds), so every call is funneled through a private serial
/// queue and exposed to callers as `async`. The UI thread never blocks and the
/// raw `virDomainPtr`/`virConnectPtr` handles never escape this type.
public final class LibvirtConnection: @unchecked Sendable {
    private let conn: OpaquePointer
    private let queue: DispatchQueue
    public let uri: String

    private init(conn: OpaquePointer, uri: String) {
        self.conn = conn
        self.uri = uri
        self.queue = DispatchQueue(label: "libvirt.\(uri)")
    }

    // MARK: - Open / close

    /// Opens a connection to the given libvirt URI. `qemu+ssh` authentication is
    /// delegated to the system `ssh` (keys / ssh-agent), so no interactive prompt
    /// is needed for key auth.
    public static func open(uri: String) async throws -> LibvirtConnection {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let conn = virConnectOpen(uri) else {
                    cont.resume(throwing: LibvirtError.lastError(
                        fallback: "Failed to connect to \(uri)"))
                    return
                }
                VMMLog.libvirt.info("Opened \(uri, privacy: .public)")
                cont.resume(returning: LibvirtConnection(conn: conn, uri: uri))
            }
        }
    }

    public func close() {
        queue.async {
            virConnectClose(self.conn)
        }
    }

    /// The hostname libvirt reports for this connection (best-effort).
    public func hostname() async -> String? {
        await withCheckedContinuation { cont in
            queue.async {
                if let c = virConnectGetHostname(self.conn) {
                    defer { free(c) }
                    cont.resume(returning: String(cString: c))
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    /// Whether the underlying transport (unix socket / SSH tunnel) is still
    /// usable. Once this returns false the handle never recovers — the only
    /// remedy is to open a new connection.
    public func isAlive() async -> Bool {
        await withCheckedContinuation { cont in
            queue.async {
                cont.resume(returning: virConnectIsAlive(self.conn) == 1)
            }
        }
    }

    // MARK: - Listing

    /// Lists all domains (active and inactive) with a snapshot of their state.
    public func listDomains() async throws -> [DomainSummary] {
        try await run { conn in
            var array: UnsafeMutablePointer<virDomainPtr?>?
            let count = virConnectListAllDomains(conn, &array, 0)
            guard count >= 0, let array else {
                throw LibvirtError.lastError(fallback: "Failed to list domains")
            }
            defer { free(array) }

            var result: [DomainSummary] = []
            result.reserveCapacity(Int(count))
            for i in 0..<Int(count) {
                guard let dom = array[i] else { continue }
                defer { virDomainFree(dom) }
                result.append(Self.summary(of: dom))
            }
            return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    // MARK: - XML

    public func domainXML(uuid: String) async throws -> String {
        try await domainXML(uuid: uuid, flags: 0)
    }

    /// Running config when the guest is active; saved config when shut off.
    public func domainLiveXML(uuid: String) async throws -> String {
        try await domainXML(uuid: uuid, flags: 0)
    }

    /// Saved (persistent) config — `VIR_DOMAIN_XML_INACTIVE`.
    public func domainPersistentXML(uuid: String) async throws -> String {
        try await domainXML(uuid: uuid, flags: UInt32(VIR_DOMAIN_XML_INACTIVE.rawValue))
    }

    public func domainXML(uuid: String, flags: UInt32) async throws -> String {
        try await run { conn in
            try Self.withDomain(conn, uuid: uuid) { dom in
                guard let cstr = virDomainGetXMLDesc(dom, flags) else {
                    throw LibvirtError.lastError(fallback: "Failed to read domain XML")
                }
                defer { free(cstr) }
                return String(cString: cstr)
            }
        }
    }

    /// Whether live changes have not been saved to the persistent definition.
    public func domainIsUpdated(uuid: String) async throws -> Bool {
        try await run { conn in
            try Self.withDomain(conn, uuid: uuid) { dom in
                guard virDomainIsActive(dom) == 1 else { return false }
                let rc = virDomainIsUpdated(dom)
                guard rc >= 0 else {
                    throw LibvirtError.lastError(fallback: "Failed to query domain update state")
                }
                return rc == 1
            }
        }
    }

    /// Defines (creates or updates) a domain from XML. Returns the resulting
    /// domain summary.
    @discardableResult
    public func defineXML(_ xml: String) async throws -> DomainSummary {
        try await run { conn in
            guard let dom = virDomainDefineXML(conn, xml) else {
                throw LibvirtError.lastError(fallback: "Failed to define domain")
            }
            defer { virDomainFree(dom) }
            return Self.summary(of: dom)
        }
    }

    /// Updates a single device in place (e.g. CD-ROM media change/eject).
    /// `live` applies to the running guest, `persistent` to the stored config.
    public func updateDevice(uuid: String, deviceXML: String,
                             live: Bool, persistent: Bool) async throws {
        try await run { conn in
            try Self.withDomain(conn, uuid: uuid) { dom in
                var flags: UInt32 = 0
                if live { flags |= VIR_DOMAIN_DEVICE_MODIFY_LIVE.rawValue }
                if persistent { flags |= VIR_DOMAIN_DEVICE_MODIFY_CONFIG.rawValue }
                guard virDomainUpdateDeviceFlags(dom, deviceXML, flags) == 0 else {
                    throw LibvirtError.lastError(fallback: "Failed to update device")
                }
            }
        }
    }

    /// Attaches a new device. `live` plugs it into the running guest;
    /// `persistent` adds it to the stored config.
    public func attachDevice(uuid: String, deviceXML: String,
                             live: Bool, persistent: Bool) async throws {
        try await run { conn in
            try Self.withDomain(conn, uuid: uuid) { dom in
                var flags: UInt32 = 0
                if live { flags |= VIR_DOMAIN_DEVICE_MODIFY_LIVE.rawValue }
                if persistent { flags |= VIR_DOMAIN_DEVICE_MODIFY_CONFIG.rawValue }
                guard virDomainAttachDeviceFlags(dom, deviceXML, flags) == 0 else {
                    throw LibvirtError.lastError(fallback: "Failed to attach device")
                }
            }
        }
    }

    /// Detaches a device (matched by target/address from the XML).
    public func detachDevice(uuid: String, deviceXML: String,
                             live: Bool, persistent: Bool) async throws {
        try await run { conn in
            try Self.withDomain(conn, uuid: uuid) { dom in
                var flags: UInt32 = 0
                if live { flags |= VIR_DOMAIN_DEVICE_MODIFY_LIVE.rawValue }
                if persistent { flags |= VIR_DOMAIN_DEVICE_MODIFY_CONFIG.rawValue }
                guard virDomainDetachDeviceFlags(dom, deviceXML, flags) == 0 else {
                    throw LibvirtError.lastError(fallback: "Failed to detach device")
                }
            }
        }
    }

    /// Changes the vCPU count on the running guest (and the config).
    public func setVcpusLive(uuid: String, count: Int) async throws {
        try await run { conn in
            try Self.withDomain(conn, uuid: uuid) { dom in
                let flags = VIR_DOMAIN_AFFECT_LIVE.rawValue | VIR_DOMAIN_AFFECT_CONFIG.rawValue
                guard virDomainSetVcpusFlags(dom, UInt32(count), flags) == 0 else {
                    throw LibvirtError.lastError(fallback: "Failed to set vCPUs")
                }
            }
        }
    }

    /// Changes the guest's memory balloon on the running guest (and config).
    /// Bounded by the domain's maximum memory.
    public func setMemoryLive(uuid: String, kib: UInt64) async throws {
        try await run { conn in
            try Self.withDomain(conn, uuid: uuid) { dom in
                let flags = VIR_DOMAIN_AFFECT_LIVE.rawValue | VIR_DOMAIN_AFFECT_CONFIG.rawValue
                guard virDomainSetMemoryFlags(dom, UInt(kib), flags) == 0 else {
                    throw LibvirtError.lastError(fallback: "Failed to set memory")
                }
            }
        }
    }

    // MARK: - Autostart

    public func autostart(uuid: String) async throws -> Bool {
        try await run { conn in
            try Self.withDomain(conn, uuid: uuid) { dom in
                var flag: Int32 = 0
                return virDomainGetAutostart(dom, &flag) == 0 && flag != 0
            }
        }
    }

    public func setAutostart(uuid: String, _ on: Bool) async throws {
        try await run { conn in
            try Self.withDomain(conn, uuid: uuid) { dom in
                if virDomainSetAutostart(dom, on ? 1 : 0) < 0 {
                    throw LibvirtError.lastError(fallback: "Failed to set autostart")
                }
            }
        }
    }

    /// Removes a domain definition without cleanup flags (for the test driver).
    public func undefineBasic(uuid: String) async throws {
        try await run { conn in
            try Self.withDomain(conn, uuid: uuid) { dom in
                guard virDomainUndefine(dom) == 0 else {
                    throw LibvirtError.lastError(fallback: "Failed to undefine domain")
                }
            }
        }
    }

    // MARK: - Managed save

    public func hasManagedSave(uuid: String) async throws -> Bool {
        try await run { conn in
            try Self.withDomain(conn, uuid: uuid) { dom in
                virDomainHasManagedSaveImage(dom, 0) == 1
            }
        }
    }

    public func removeManagedSave(uuid: String) async throws {
        try await run { conn in
            try Self.withDomain(conn, uuid: uuid) { dom in
                guard virDomainManagedSaveRemove(dom, 0) == 0 else {
                    throw LibvirtError.lastError(fallback: "Failed to remove saved state")
                }
            }
        }
    }

    // MARK: - Lifecycle

    public func perform(_ action: DomainAction, uuid: String) async throws {
        try await run { conn in
            try Self.withDomain(conn, uuid: uuid) { dom in
                let rc: Int32
                switch action {
                case .start:    rc = virDomainCreate(dom)
                case .shutdown: rc = virDomainShutdown(dom)
                case .reboot:   rc = virDomainReboot(dom, 0)
                case .forceOff: rc = virDomainDestroy(dom)
                case .pause:    rc = virDomainSuspend(dom)
                case .resume:   rc = virDomainResume(dom)
                case .save:     rc = virDomainManagedSave(dom, 0)
                case .undefine:
                    // Full cleanup so undefine never fails on leftovers: UEFI
                    // NVRAM, a managed-save image, snapshot/checkpoint metadata.
                    let flags = VIR_DOMAIN_UNDEFINE_MANAGED_SAVE.rawValue
                              | VIR_DOMAIN_UNDEFINE_SNAPSHOTS_METADATA.rawValue
                              | VIR_DOMAIN_UNDEFINE_NVRAM.rawValue
                              | VIR_DOMAIN_UNDEFINE_CHECKPOINTS_METADATA.rawValue
                    rc = virDomainUndefineFlags(dom, flags)
                }
                if rc < 0 {
                    throw LibvirtError.lastError(fallback: "Operation failed")
                }
            }
        }
    }

    /// Clones a storage volume within its pool (same capacity and format).
    /// Returns the new volume's path.
    public func cloneVolume(path: String, newName: String) async throws -> String {
        try await run { conn in
            guard let src = virStorageVolLookupByPath(conn, path) else {
                throw LibvirtError.lastError(fallback: "\(path) is not managed by a storage pool")
            }
            defer { virStorageVolFree(src) }
            guard let pool = virStoragePoolLookupByVolume(src) else {
                throw LibvirtError.lastError(fallback: "No pool for \(path)")
            }
            defer { virStoragePoolFree(pool) }

            var info = virStorageVolInfo()
            virStorageVolGetInfo(src, &info)
            // Keep the source's format (parse it from the volume XML).
            var format = "qcow2"
            if let xmlC = virStorageVolGetXMLDesc(src, 0) {
                defer { free(xmlC) }
                if let doc = try? XMLDocument(xmlString: String(cString: xmlC)),
                   let f = doc.rootElement()?.elements(forName: "target").first?
                       .elements(forName: "format").first?
                       .attribute(forName: "type")?.stringValue {
                    format = f
                }
            }
            let xml = """
            <volume>
              <name>\(Self.xmlEscape(newName))</name>
              <capacity>\(info.capacity)</capacity>
              <target><format type='\(format)'/></target>
            </volume>
            """
            guard let vol = virStorageVolCreateXMLFrom(pool, xml, src, 0) else {
                throw LibvirtError.lastError(fallback: "Failed to clone \(path)")
            }
            defer { virStorageVolFree(vol) }
            guard let p = virStorageVolGetPath(vol) else {
                throw LibvirtError.lastError(fallback: "Clone created but has no path")
            }
            defer { free(p) }
            return String(cString: p)
        }
    }

    /// Deletes a storage volume by its path (the file backing a VM disk).
    /// Fails if the path doesn't belong to any libvirt storage pool.
    public func deleteVolume(path: String) async throws {
        try await run { conn in
            guard let vol = virStorageVolLookupByPath(conn, path) else {
                throw LibvirtError.lastError(fallback: "\(path) is not managed by a storage pool")
            }
            defer { virStorageVolFree(vol) }
            guard virStorageVolDelete(vol, 0) == 0 else {
                throw LibvirtError.lastError(fallback: "Failed to delete \(path)")
            }
        }
    }

    // MARK: - Helpers

    func run<T: Sendable>(
        _ body: @escaping @Sendable (OpaquePointer) throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do { cont.resume(returning: try body(self.conn)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    /// The raw handle for long-running stream transfers that must not occupy
    /// the serial queue (virConnect is thread-safe per libvirt's guarantees).
    func rawConnectionForStreaming() -> OpaquePointer { conn }

    /// Looks up a domain by UUID, runs `body`, and always frees the handle.
    static func withDomain<T>(
        _ conn: OpaquePointer, uuid: String, _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        guard let dom = virDomainLookupByUUIDString(conn, uuid) else {
            throw LibvirtError.lastError(fallback: "Domain \(uuid) not found")
        }
        defer { virDomainFree(dom) }
        return try body(dom)
    }

    /// Extracts an immutable summary from a live `virDomainPtr`.
    static func domainSummary(from dom: OpaquePointer) -> DomainSummary {
        summary(of: dom)
    }

    private static func summary(of dom: OpaquePointer) -> DomainSummary {
        let name = virDomainGetName(dom).map { String(cString: $0) } ?? "(unnamed)"

        var uuidBuf = [CChar](repeating: 0, count: 37) // VIR_UUID_STRING_BUFLEN
        _ = virDomainGetUUIDString(dom, &uuidBuf)
        let uuid = String(cString: &uuidBuf)

        let rawID = virDomainGetID(dom)
        let id: Int32 = rawID == UInt32.max ? -1 : Int32(rawID)

        var stateRaw: Int32 = 0
        var reason: Int32 = 0
        _ = virDomainGetState(dom, &stateRaw, &reason, 0)

        var info = virDomainInfo()
        let vcpus: Int
        let mem: UInt64
        let maxMem: UInt64
        if virDomainGetInfo(dom, &info) == 0 {
            vcpus = Int(info.nrVirtCpu)
            mem = UInt64(info.memory)
            maxMem = UInt64(info.maxMem)
        } else {
            vcpus = 0; mem = 0; maxMem = 0
        }

        return DomainSummary(
            uuid: uuid, name: name, domainID: id,
            state: DomainState(raw: stateRaw),
            vcpus: vcpus, memoryKiB: mem, maxMemoryKiB: maxMem)
    }
}
