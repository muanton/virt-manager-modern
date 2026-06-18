import Foundation
import LibvirtKit
import DomainModel

/// Live state for one connection: the open libvirt handle, its domains, and a
/// background poll that keeps stats fresh. Domain list updates are event-driven.
@MainActor
final class ConnectionSession: ObservableObject, Identifiable {
    enum Status: Equatable {
        case disconnected
        case connecting
        case connected
        case reconnecting
        case failed(String)
    }

    let config: ConnectionConfig
    nonisolated var id: UUID { config.id }

    @Published private(set) var status: Status = .disconnected
    @Published private(set) var domains: [DomainSummary] = []
    @Published private(set) var stats: [String: VMStats] = [:]
    @Published private(set) var configDrift: [String: Bool] = [:]
    @Published private(set) var pools: [StoragePoolInfo] = []

    struct VMStats {
        var cpuPercent: Double
        var memUsedKiB: UInt64
        var memTotalKiB: UInt64
        var diskReadBps: UInt64
        var diskWriteBps: UInt64
        var netRxBps: UInt64
        var netTxBps: UInt64
    }
    private var lastCPUSamples: [String: (timeNs: UInt64, at: Date)] = [:]
    private var lastBlockSamples: [String: (readBytes: UInt64, writeBytes: UInt64, at: Date)] = [:]
    private var lastNetSamples: [String: (rxBytes: UInt64, txBytes: UInt64, at: Date)] = [:]

    @Published private(set) var networks: [VirtNetwork] = []
    @Published private(set) var volumes: [StorageVolume] = []
    @Published private(set) var usbDevices: [NodeDevice] = []
    @Published private(set) var pciDevices: [NodeDevice] = []
    @Published private(set) var domainCaps: DomainCaps = .fallback
    @Published private(set) var hostSummary: HostSummary?
    @Published private(set) var hostMemoryStats: HostMemoryStats?
    private var hostResourcesLoaded = false

    private var conn: LibvirtConnection?
    private var deregisterEvents: (() -> Void)?
    private var deregisterPoolEvents: (() -> Void)?
    private var pollTask: Task<Void, Never>?

    init(config: ConnectionConfig) {
        self.config = config
    }

    var isConnected: Bool { status == .connected }

    func connect() async {
        guard conn == nil else { return }
        status = .connecting
        VMMLog.session.info("Connecting to \(self.config.name, privacy: .public)")
        do {
            let c = try await LibvirtConnection.open(uri: config.uri)
            conn = c
            status = .connected
            try await startDomainEvents(on: c)
            try await startStoragePoolEvents(on: c)
            await refreshDomainList()
            await refreshHostSummary()
            startPolling()
            VMMLog.session.info("Connected to \(self.config.name, privacy: .public) (\(self.domains.count) VMs)")
        } catch {
            status = .failed(error.localizedDescription)
            VMMLog.session.error("Connect failed for \(self.config.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func disconnect() {
        VMMLog.session.info("Disconnecting \(self.config.name, privacy: .public)")
        pollTask?.cancel()
        pollTask = nil
        deregisterEvents?()
        deregisterEvents = nil
        deregisterPoolEvents?()
        deregisterPoolEvents = nil
        conn?.close()
        conn = nil
        domains = []
        pools = []
        hostSummary = nil
        hostMemoryStats = nil
        status = .disconnected
    }

    // MARK: - Domain list (events + explicit refresh)

    func refreshDomainList() async {
        guard let conn else { return }
        do {
            domains = try await conn.listDomains()
        } catch {
            if await !conn.isAlive() { beginReconnect() }
        }
    }

    private func handleDomainEvent(_ kind: DomainLifecycleEvent, summary: DomainSummary?) {
        if let name = summary?.name {
            VMMLog.session.debug("Domain event \(String(describing: kind), privacy: .public) on \(name, privacy: .public)")
        }
        switch kind {
        case .undefined:
            if let uuid = summary?.uuid {
                domains.removeAll { $0.uuid == uuid }
                stats.removeValue(forKey: uuid)
                configDrift.removeValue(forKey: uuid)
                lastCPUSamples.removeValue(forKey: uuid)
                lastBlockSamples.removeValue(forKey: uuid)
                lastNetSamples.removeValue(forKey: uuid)
            } else {
                Task { await refreshDomainList() }
            }
            Task { await refreshHostSummary() }
        case .defined:
            if let s = summary { upsertDomain(s) }
            else { Task { await refreshDomainList() } }
            Task { await refreshHostSummary() }
        default:
            if let s = summary { upsertDomain(s) }
            else { Task { await refreshDomainList() } }
            Task {
                await refreshStats()
                await refreshConfigDrift()
            }
        }
    }

    private func upsertDomain(_ summary: DomainSummary) {
        if let idx = domains.firstIndex(where: { $0.uuid == summary.uuid }) {
            domains[idx] = summary
        } else {
            domains.append(summary)
            domains.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    private func beginReconnect() {
        guard status == .connected, let dead = conn else { return }
        VMMLog.session.notice("Transport lost for \(self.config.name, privacy: .public) — reconnecting")
        deregisterEvents?()
        deregisterEvents = nil
        deregisterPoolEvents?()
        deregisterPoolEvents = nil
        dead.close()
        conn = nil
        stats = [:]
        configDrift = [:]
        lastCPUSamples = [:]
        lastBlockSamples = [:]
        lastNetSamples = [:]
        status = .reconnecting
    }

    private func attemptReconnect() async {
        guard conn == nil, status == .reconnecting else { return }
        do {
            let c = try await LibvirtConnection.open(uri: config.uri)
            conn = c
            status = .connected
            hostResourcesLoaded = false
            try await startDomainEvents(on: c)
            try await startStoragePoolEvents(on: c)
            await refreshDomainList()
            await refreshHostSummary()
            VMMLog.session.info("Reconnected to \(self.config.name, privacy: .public)")
        } catch { /* poll loop retries */ }
    }

    private func startDomainEvents(on conn: LibvirtConnection) async throws {
        deregisterEvents?()
        deregisterEvents = try await conn.registerDomainEvents { [weak self] kind, summary in
            Task { @MainActor [weak self] in
                self?.handleDomainEvent(kind, summary: summary)
            }
        }
    }

    private func startStoragePoolEvents(on conn: LibvirtConnection) async throws {
        deregisterPoolEvents?()
        deregisterPoolEvents = try await conn.registerStoragePoolEvents(
            onLifecycle: { [weak self] _, _ in
                Task { @MainActor [weak self] in await self?.handleStoragePoolChange() }
            },
            onRefresh: { [weak self] _ in
                Task { @MainActor [weak self] in await self?.handleStoragePoolChange() }
            })
    }

    private func handleStoragePoolChange() async {
        guard conn != nil else { return }
        try? await loadStoragePools()
    }

    func refreshHostSummary() async {
        guard let conn else { return }
        if let summary = try? await conn.hostSummary() {
            hostSummary = summary
            hostMemoryStats = summary.memory
        } else {
            hostSummary = nil
        }
        if hostMemoryStats == nil {
            hostMemoryStats = try? await conn.nodeMemoryStats()
        }
    }

    func refreshHostMemoryStats() async {
        guard let conn else { return }
        hostMemoryStats = try? await conn.nodeMemoryStats()
    }

    func hasManagedSave(uuid: String) async throws -> Bool {
        try await requireConnection().hasManagedSave(uuid: uuid)
    }

    func removeManagedSave(uuid: String) async throws {
        try await requireConnection().removeManagedSave(uuid: uuid)
    }

    func networkXML(name: String) async throws -> String {
        try await requireConnection().networkXML(name: name)
    }

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

            var readBps: UInt64 = 0, writeBps: UInt64 = 0
            if let prev = lastBlockSamples[uuid],
               s.blockReadBytes >= prev.readBytes, s.blockWriteBytes >= prev.writeBytes {
                let elapsed = now.timeIntervalSince(prev.at)
                if elapsed > 0.2 {
                    readBps = UInt64(Double(s.blockReadBytes - prev.readBytes) / elapsed)
                    writeBps = UInt64(Double(s.blockWriteBytes - prev.writeBytes) / elapsed)
                } else {
                    readBps = stats[uuid]?.diskReadBps ?? 0
                    writeBps = stats[uuid]?.diskWriteBps ?? 0
                }
            }
            lastBlockSamples[uuid] = (s.blockReadBytes, s.blockWriteBytes, now)

            var rxBps: UInt64 = 0, txBps: UInt64 = 0
            if let prev = lastNetSamples[uuid],
               s.netRxBytes >= prev.rxBytes, s.netTxBytes >= prev.txBytes {
                let elapsed = now.timeIntervalSince(prev.at)
                if elapsed > 0.2 {
                    rxBps = UInt64(Double(s.netRxBytes - prev.rxBytes) / elapsed)
                    txBps = UInt64(Double(s.netTxBytes - prev.txBytes) / elapsed)
                } else {
                    rxBps = stats[uuid]?.netRxBps ?? 0
                    txBps = stats[uuid]?.netTxBps ?? 0
                }
            }
            lastNetSamples[uuid] = (s.netRxBytes, s.netTxBytes, now)

            next[uuid] = VMStats(cpuPercent: cpu,
                                 memUsedKiB: s.balloonRSSKiB,
                                 memTotalKiB: s.balloonCurrentKiB,
                                 diskReadBps: readBps,
                                 diskWriteBps: writeBps,
                                 netRxBps: rxBps,
                                 netTxBps: txBps)
        }
        stats = next
        lastCPUSamples = lastCPUSamples.filter { next[$0.key] != nil }
        lastBlockSamples = lastBlockSamples.filter { next[$0.key] != nil }
        lastNetSamples = lastNetSamples.filter { next[$0.key] != nil }
        await refreshConfigDrift()
    }

    func hasConfigDrift(uuid: String) -> Bool {
        configDrift[uuid] == true
    }

    func clearConfigDrift(uuid: String) {
        configDrift[uuid] = false
    }

    private func refreshConfigDrift() async {
        guard let conn else { return }
        var next: [String: Bool] = [:]
        for domain in domains where domain.isActive {
            if let updated = try? await conn.domainIsUpdated(uuid: domain.uuid) {
                next[domain.uuid] = updated
            }
        }
        configDrift = next
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { break }
                guard let self else { break }
                if self.status == .reconnecting {
                    await self.attemptReconnect()
                } else if self.status == .connected {
                    if let conn = self.conn, await !conn.isAlive() {
                        self.beginReconnect()
                    } else {
                        await self.refreshStats()
                        await self.refreshHostMemoryStats()
                    }
                }
            }
        }
    }

    // MARK: - Errors

    private func requireConnection() throws -> LibvirtConnection {
        guard let conn else { throw LibvirtError(message: "Not connected to \(config.name)") }
        return conn
    }

    // MARK: - Queries

    func interfaceAddresses(uuid: String) async throws -> [IfaceAddr] {
        try await requireConnection().interfaceAddresses(uuid: uuid)
    }

    func guestAgentStatus(uuid: String) async throws -> GuestAgentStatus {
        try await requireConnection().guestAgentStatus(uuid: uuid)
    }

    func guestInfo(uuid: String) async throws -> GuestInfo {
        try await requireConnection().guestInfo(uuid: uuid)
    }

    func domainXML(uuid: String) async throws -> String {
        try await requireConnection().domainXML(uuid: uuid)
    }

    func domainLiveXML(uuid: String) async throws -> String {
        try await requireConnection().domainLiveXML(uuid: uuid)
    }

    func domainPersistentXML(uuid: String) async throws -> String {
        try await requireConnection().domainPersistentXML(uuid: uuid)
    }

    func domainIsUpdated(uuid: String) async throws -> Bool {
        try await requireConnection().domainIsUpdated(uuid: uuid)
    }

    func snapshots(uuid: String) async throws -> [Snapshot] {
        try await requireConnection().listSnapshots(uuid: uuid)
    }

    func domain(uuid: String) -> DomainSummary? {
        domains.first { $0.uuid == uuid }
    }

    func autostart(uuid: String) async throws -> Bool {
        try await requireConnection().autostart(uuid: uuid)
    }

    // MARK: - Mutations

    @discardableResult
    func defineXML(_ xml: String) async throws -> DomainSummary {
        let summary = try await requireConnection().defineXML(xml)
        await refreshDomainList()
        return summary
    }

    func defineAndReturnUUID(_ xml: String) async throws -> String {
        try await defineXML(xml).uuid
    }

    func createDomain(xml: String) async throws -> String {
        try await defineAndReturnUUID(xml)
    }

    func cloneVolume(path: String, newName: String) async throws -> String {
        let p = try await requireConnection().cloneVolume(path: path, newName: newName)
        hostResourcesLoaded = false
        return p
    }

    func uploadISO(pool: String, name: String, localURL: URL,
                   progress: @escaping @MainActor (Double) -> Void) async throws -> String {
        let path = try await requireConnection().uploadVolume(pool: pool, name: name, localURL: localURL) { p in
            Task { @MainActor in progress(p) }
        }
        await loadHostResources(force: true)
        return path
    }

    func downloadVolume(path: String, localURL: URL,
                        progress: @escaping @MainActor (Double) -> Void) async throws {
        try await requireConnection().downloadVolume(path: path, localURL: localURL) { p in
            Task { @MainActor in progress(p) }
        }
    }

    func openSerialConsole(uuid: String,
                           onData: @escaping @Sendable (Data) -> Void,
                           onClose: @escaping @Sendable (String?) -> Void) async throws -> SerialConsoleHandle {
        try await requireConnection().openSerialConsole(uuid: uuid, onData: onData, onClose: onClose)
    }

    func attachDevice(uuid: String, xml: String, live: Bool, persistent: Bool) async throws {
        try await requireConnection().attachDevice(uuid: uuid, deviceXML: xml, live: live, persistent: persistent)
    }

    func detachDevice(uuid: String, xml: String, live: Bool, persistent: Bool) async throws {
        try await requireConnection().detachDevice(uuid: uuid, deviceXML: xml, live: live, persistent: persistent)
    }

    func setVcpusLive(uuid: String, count: Int) async throws {
        try await requireConnection().setVcpusLive(uuid: uuid, count: count)
        await refreshDomainList()
    }

    func setMemoryLive(uuid: String, kib: UInt64) async throws {
        try await requireConnection().setMemoryLive(uuid: uuid, kib: kib)
        await refreshDomainList()
    }

    func createSnapshot(uuid: String, name: String, description: String) async throws {
        try await requireConnection().createSnapshot(uuid: uuid, name: name, description: description)
    }

    func revertToSnapshot(uuid: String, name: String) async throws {
        try await requireConnection().revertToSnapshot(uuid: uuid, name: name)
        await refreshDomainList()
    }

    func deleteSnapshot(uuid: String, name: String) async throws {
        try await requireConnection().deleteSnapshot(uuid: uuid, name: name)
    }

    func perform(_ action: DomainAction, on uuid: String) async throws {
        let conn = try requireConnection()
        if let name = domain(uuid: uuid)?.name {
            VMMLog.session.info("\(String(describing: action), privacy: .public) on \(name, privacy: .public)")
        }
        switch action {
        case .shutdown, .reboot, .forceOff: await ejectAllCDROMs(uuid: uuid)
        default: break
        }
        try await conn.perform(action, uuid: uuid)
        await refreshDomainList()
        await refreshStats()
    }

    /// Deletes a VM and optionally its storage. Throws on failure; returns a
    /// warning string when the VM was removed but some disks could not be deleted.
    func deleteVM(uuid: String, deleteStoragePaths: [String]) async throws -> String? {
        let conn = try requireConnection()
        if domain(uuid: uuid)?.isActive == true {
            try await conn.perform(.forceOff, uuid: uuid)
        }
        try await conn.perform(.undefine, uuid: uuid)

        var failures: [String] = []
        for path in deleteStoragePaths {
            do { try await conn.deleteVolume(path: path) }
            catch { failures.append("\(path): \(error.localizedDescription)") }
        }
        await refreshDomainList()
        hostResourcesLoaded = false
        guard failures.isEmpty else {
            return "The VM was deleted, but some storage could not be removed:\n"
                + failures.joined(separator: "\n")
        }
        return nil
    }

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

    func ejectCDROM(uuid: String, deviceID: String) async throws {
        let conn = try requireConnection()
        let xml = try await conn.domainXML(uuid: uuid)
        let cfg = try DomainConfig(xml: xml)
        guard let deviceXML = cfg.cdromEjectXML(deviceID: deviceID) else {
            throw LibvirtError(message: "CD-ROM device not found")
        }
        try await conn.updateDevice(uuid: uuid, deviceXML: deviceXML,
                                    live: domain(uuid: uuid)?.isActive ?? false,
                                    persistent: true)
    }

    func setAutostart(uuid: String, _ on: Bool) async throws {
        try await requireConnection().setAutostart(uuid: uuid, on)
    }

    func createVolume(pool: String, name: String, capacityBytes: UInt64,
                      format: String) async throws -> StorageVolume {
        let vol = try await requireConnection().createVolume(pool: pool, name: name,
                                                             capacityBytes: capacityBytes, format: format)
        volumes.append(vol)
        try await loadStoragePools()
        return vol
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
        async let pl = try? conn.listStoragePools()
        networks = await n ?? []
        volumes = await v ?? []
        usbDevices = await u ?? []
        pciDevices = await p ?? []
        domainCaps = await c ?? .fallback
        pools = await pl ?? []
    }

    func loadStoragePools() async throws {
        pools = try await requireConnection().listStoragePools()
        volumes = try await requireConnection().listVolumes()
        hostResourcesLoaded = true
    }

    func setPoolActive(name: String, active: Bool) async throws {
        try await requireConnection().setStoragePoolActive(name: name, active: active)
        try await loadStoragePools()
    }

    func refreshPool(name: String) async throws {
        try await requireConnection().refreshStoragePool(name: name)
        try await loadStoragePools()
    }

    func deleteVolume(path: String) async throws {
        try await requireConnection().deleteVolume(path: path)
        volumes.removeAll { $0.path == path }
    }

    func resizeVolume(path: String, capacityBytes: UInt64) async throws {
        try await requireConnection().resizeVolume(path: path, capacityBytes: capacityBytes)
        try await loadStoragePools()
    }

    func wipeVolume(path: String) async throws {
        try await requireConnection().wipeVolume(path: path)
    }

    func screenshot(uuid: String) async throws -> DomainScreenshot {
        try await requireConnection().screenshot(uuid: uuid)
    }

    func loadNetworks() async throws {
        networks = try await requireConnection().listNetworks()
        hostResourcesLoaded = true
    }

    @discardableResult
    func defineNetwork(xml: String) async throws -> VirtNetwork {
        let net = try await requireConnection().defineNetwork(xml: xml)
        try await loadNetworks()
        return net
    }

    func setNetworkActive(name: String, active: Bool) async throws {
        try await requireConnection().setNetworkActive(name: name, active: active)
        try await loadNetworks()
    }

    func undefineNetwork(name: String) async throws {
        try await requireConnection().undefineNetwork(name: name)
        try await loadNetworks()
    }

    var storagePools: [String] {
        let names = Set(volumes.map(\.pool))
        if !names.isEmpty { return names.sorted() }
        if !pools.isEmpty { return pools.map(\.name).sorted() }
        return ["default"]
    }
}