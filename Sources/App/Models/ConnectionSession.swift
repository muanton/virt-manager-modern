import Foundation
import LibvirtKit
import DomainModel

/// Live state for one connection: the open libvirt handle, its domains, and a
/// background poll that keeps domain state fresh. UI-facing, so `@MainActor`.
@MainActor
final class ConnectionSession: ObservableObject, Identifiable {
    enum Status: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    let config: ConnectionConfig
    nonisolated var id: UUID { config.id }

    @Published private(set) var status: Status = .disconnected
    @Published private(set) var domains: [DomainSummary] = []
    @Published private(set) var stats: [String: VMStats] = [:]   // uuid → live usage
    @Published var lastError: String?

    struct VMStats {
        var cpuPercent: Double
        var memUsedKiB: UInt64
        var memTotalKiB: UInt64
    }
    private var lastCPUSamples: [String: (timeNs: UInt64, at: Date)] = [:]

    // Host resources for the hardware forms (loaded lazily, cached).
    @Published private(set) var networks: [VirtNetwork] = []
    @Published private(set) var volumes: [StorageVolume] = []
    @Published private(set) var usbDevices: [NodeDevice] = []
    @Published private(set) var pciDevices: [NodeDevice] = []
    @Published private(set) var domainCaps: DomainCaps = .fallback
    private var hostResourcesLoaded = false

    private var conn: LibvirtConnection?
    private var pollTask: Task<Void, Never>?

    init(config: ConnectionConfig) {
        self.config = config
    }

    var isConnected: Bool { status == .connected }

    func connect() async {
        guard conn == nil else { return }
        status = .connecting
        do {
            let c = try await LibvirtConnection.open(uri: config.uri)
            conn = c
            status = .connected
            await refresh()
            startPolling()
        } catch {
            status = .failed(error.localizedDescription)
            lastError = error.localizedDescription
        }
    }

    func disconnect() {
        pollTask?.cancel()
        pollTask = nil
        conn?.close()
        conn = nil
        domains = []
        status = .disconnected
    }

    func refresh() async {
        guard let conn else { return }
        do {
            domains = try await conn.listDomains()
        } catch {
            lastError = error.localizedDescription
        }
        await refreshStats()
    }

    /// CPU % + memory per running VM, derived from the bulk stats call.
    /// CPU % = guest cpu_time delta / (wall-clock delta × vCPUs).
    private func refreshStats() async {
        guard let conn, let raw = try? await conn.allDomainStats() else { return }
        let now = Date()
        var next: [String: VMStats] = [:]
        for (uuid, s) in raw {
            var cpu: Double = 0
            if let prev = lastCPUSamples[uuid], s.cpuTimeNs >= prev.timeNs {
                let elapsed = now.timeIntervalSince(prev.at)
                let vcpus = max(1, s.vcpuCount)
                if elapsed > 0.2 {
                    cpu = Double(s.cpuTimeNs - prev.timeNs) / (elapsed * 1e9 * Double(vcpus)) * 100
                    cpu = min(100, max(0, cpu))
                } else {
                    cpu = stats[uuid]?.cpuPercent ?? 0
                }
            }
            lastCPUSamples[uuid] = (s.cpuTimeNs, now)
            next[uuid] = VMStats(cpuPercent: cpu,
                                 memUsedKiB: s.balloonRSSKiB,
                                 memTotalKiB: s.balloonCurrentKiB)
        }
        stats = next
        lastCPUSamples = lastCPUSamples.filter { next[$0.key] != nil }
    }

    /// Guest interface addresses (agent → DHCP-lease fallback). On-demand.
    func interfaceAddresses(uuid: String) async -> [IfaceAddr] {
        guard let conn else { return [] }
        return (try? await conn.interfaceAddresses(uuid: uuid)) ?? []
    }

    /// Defines a domain and returns its UUID (used by Clone).
    func defineAndReturnUUID(_ xml: String) async -> String? {
        guard let conn else { return nil }
        do {
            let summary = try await conn.defineXML(xml)
            await refresh()
            return summary.uuid
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Clones a volume in its pool; returns the new path.
    func cloneVolume(path: String, newName: String) async -> String? {
        guard let conn else { return nil }
        do {
            let p = try await conn.cloneVolume(path: path, newName: newName)
            hostResourcesLoaded = false
            return p
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Uploads a local file (ISO) into a pool; returns the new volume path.
    /// `progress` arrives on the main actor (0…1).
    func uploadISO(pool: String, name: String, localURL: URL,
                   progress: @escaping @MainActor (Double) -> Void) async -> String? {
        guard let conn else { return nil }
        do {
            let path = try await conn.uploadVolume(pool: pool, name: name, localURL: localURL) { p in
                Task { @MainActor in progress(p) }
            }
            await loadHostResources(force: true)
            return path
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Opens the VM's serial console stream (see SerialConsoleView).
    func openSerialConsole(uuid: String,
                           onData: @escaping @Sendable (Data) -> Void,
                           onClose: @escaping @Sendable (String?) -> Void) async -> SerialConsoleHandle? {
        guard let conn else { return nil }
        do { return try await conn.openSerialConsole(uuid: uuid, onData: onData, onClose: onClose) }
        catch { lastError = error.localizedDescription; return nil }
    }

    // MARK: - Live hotplug / resize

    func attachDevice(uuid: String, xml: String, live: Bool, persistent: Bool) async -> Bool {
        guard let conn else { return false }
        do { try await conn.attachDevice(uuid: uuid, deviceXML: xml, live: live, persistent: persistent); return true }
        catch { lastError = error.localizedDescription; return false }
    }

    func detachDevice(uuid: String, xml: String, live: Bool, persistent: Bool) async -> Bool {
        guard let conn else { return false }
        do { try await conn.detachDevice(uuid: uuid, deviceXML: xml, live: live, persistent: persistent); return true }
        catch { lastError = error.localizedDescription; return false }
    }

    func setVcpusLive(uuid: String, count: Int) async -> Bool {
        guard let conn else { return false }
        do { try await conn.setVcpusLive(uuid: uuid, count: count); await refresh(); return true }
        catch { lastError = error.localizedDescription; return false }
    }

    func setMemoryLive(uuid: String, kib: UInt64) async -> Bool {
        guard let conn else { return false }
        do { try await conn.setMemoryLive(uuid: uuid, kib: kib); await refresh(); return true }
        catch { lastError = error.localizedDescription; return false }
    }

    // MARK: - Snapshots

    func snapshots(uuid: String) async -> [Snapshot]? {
        guard let conn else { return nil }
        do { return try await conn.listSnapshots(uuid: uuid) }
        catch { lastError = error.localizedDescription; return nil }
    }

    func createSnapshot(uuid: String, name: String, description: String) async -> Bool {
        guard let conn else { return false }
        do { try await conn.createSnapshot(uuid: uuid, name: name, description: description); return true }
        catch { lastError = error.localizedDescription; return false }
    }

    func revertToSnapshot(uuid: String, name: String) async -> Bool {
        guard let conn else { return false }
        do {
            try await conn.revertToSnapshot(uuid: uuid, name: name)
            await refresh()
            return true
        } catch { lastError = error.localizedDescription; return false }
    }

    func deleteSnapshot(uuid: String, name: String) async -> Bool {
        guard let conn else { return false }
        do { try await conn.deleteSnapshot(uuid: uuid, name: name); return true }
        catch { lastError = error.localizedDescription; return false }
    }

    func perform(_ action: DomainAction, on uuid: String) async {
        guard let conn else { return }
        do {
            // A machine powers back up with an empty tray: eject all CD-ROM
            // media on shutdown/reboot so an install ISO can't boot again.
            switch action {
            case .shutdown, .reboot, .forceOff: await ejectAllCDROMs(uuid: uuid)
            default: break
            }
            try await conn.perform(action, uuid: uuid)
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Deletes a VM: force-off if running, undefine (with NVRAM/managed-save/
    /// snapshot-metadata cleanup), then best-effort delete the selected storage
    /// volumes. Per-volume failures don't abort — they're collected into
    /// `lastError` so the user knows which files were left behind.
    func deleteVM(uuid: String, deleteStoragePaths: [String]) async -> Bool {
        guard let conn else { return false }
        do {
            if domain(uuid: uuid)?.isActive == true {
                try await conn.perform(.forceOff, uuid: uuid)
            }
            try await conn.perform(.undefine, uuid: uuid)
        } catch {
            lastError = error.localizedDescription
            await refresh()
            return false
        }
        var failures: [String] = []
        for path in deleteStoragePaths {
            do { try await conn.deleteVolume(path: path) }
            catch { failures.append("\(path): \(error.localizedDescription)") }
        }
        if !failures.isEmpty {
            lastError = "The VM was deleted, but some storage could not be removed:\n"
                      + failures.joined(separator: "\n")
        }
        await refresh()
        // Volume list changed — make the next hardware/wizard view refetch.
        hostResourcesLoaded = false
        return true
    }

    /// Ejects the media from every CD-ROM drive — live (if running) and in the
    /// persistent config. Best-effort: a failure never blocks the lifecycle
    /// action that triggered it.
    func ejectAllCDROMs(uuid: String) async {
        guard let conn,
              let xml = try? await conn.domainXML(uuid: uuid),
              let cfg = try? DomainConfig(xml: xml) else { return }
        let live = domain(uuid: uuid)?.isActive ?? false
        for deviceXML in cfg.cdromEjectXMLs() {
            try? await conn.updateDevice(uuid: uuid, deviceXML: deviceXML,
                                         live: live, persistent: true)
        }
    }

    /// Ejects one CD-ROM (used by the hardware form's Eject button).
    /// Returns false (with `lastError` set) if libvirt refused.
    func ejectCDROM(uuid: String, deviceID: String) async -> Bool {
        guard let conn,
              let xml = try? await conn.domainXML(uuid: uuid),
              let cfg = try? DomainConfig(xml: xml),
              let deviceXML = cfg.cdromEjectXML(deviceID: deviceID) else { return false }
        do {
            try await conn.updateDevice(uuid: uuid, deviceXML: deviceXML,
                                        live: domain(uuid: uuid)?.isActive ?? false,
                                        persistent: true)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func domainXML(uuid: String) async -> String? {
        guard let conn else { return nil }
        do { return try await conn.domainXML(uuid: uuid) }
        catch { lastError = error.localizedDescription; return nil }
    }

    func defineXML(_ xml: String) async -> Bool {
        guard let conn else { return false }
        do {
            try await conn.defineXML(xml)
            await refresh()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func domain(uuid: String) -> DomainSummary? {
        domains.first { $0.uuid == uuid }
    }

    func autostart(uuid: String) async -> Bool {
        guard let conn else { return false }
        return (try? await conn.autostart(uuid: uuid)) ?? false
    }

    func setAutostart(uuid: String, _ on: Bool) async -> Bool {
        guard let conn else { return false }
        do { try await conn.setAutostart(uuid: uuid, on); return true }
        catch { lastError = error.localizedDescription; return false }
    }

    // MARK: - Host resources

    func loadHostResources(force: Bool = false) async {
        guard let conn, force || !hostResourcesLoaded else { return }
        hostResourcesLoaded = true
        async let n = try? conn.listNetworks()
        async let v = try? conn.listVolumes()
        async let u = try? conn.listNodeDevices(kind: .usb)
        async let p = try? conn.listNodeDevices(kind: .pci)
        async let c = try? conn.domainCapabilities()
        networks = await n ?? []
        volumes = await v ?? []
        usbDevices = await u ?? []
        pciDevices = await p ?? []
        domainCaps = await c ?? .fallback
    }

    /// Defines a brand-new domain from XML; returns its UUID.
    func createDomain(xml: String) async -> String? {
        guard let conn else { return nil }
        do {
            let summary = try await conn.defineXML(xml)
            await refresh()
            return summary.uuid
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func createVolume(pool: String, name: String, capacityBytes: UInt64,
                      format: String) async -> StorageVolume? {
        guard let conn else { return nil }
        do {
            let vol = try await conn.createVolume(pool: pool, name: name,
                                                  capacityBytes: capacityBytes, format: format)
            volumes.append(vol)
            return vol
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Storage pool names (derived from loaded volumes; falls back to "default").
    var storagePools: [String] {
        let names = Set(volumes.map(\.pool))
        return names.isEmpty ? ["default"] : names.sorted()
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { break }
                await self?.refresh()
            }
        }
    }
}
