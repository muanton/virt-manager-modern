import Foundation
import DomainModel
import LibvirtKit

/// Working-copy editing model for a VM's hardware. Holds an in-memory
/// `DomainConfig`; all edits mutate it and mark the model dirty. `apply()`
/// persists via `defineXML` (takes effect after the VM restarts).
@MainActor
final class HardwareModel: ObservableObject {
    @Published private(set) var devices: [Device] = []
    @Published var dirty = false
    @Published var loadError: String?
    @Published var applying = false
    @Published var applyMessage: String?
    @Published private(set) var liveDiffersFromSaved = false
    @Published private(set) var configChanges: [DomainConfigChange] = []
    @Published private(set) var liveXML: String?
    @Published private(set) var persistentXML: String?

    private(set) var config: DomainConfig?
    let session: ConnectionSession
    let uuid: String

    init(session: ConnectionSession, uuid: String) {
        self.session = session
        self.uuid = uuid
    }

    var networks: [VirtNetwork] { session.networks }
    var volumes: [StorageVolume] { session.volumes }
    var usbDevices: [NodeDevice] { session.usbDevices }
    var pciDevices: [NodeDevice] { session.pciDevices }
    var storagePools: [String] { session.storagePools }
    func loadHostResources() async { await session.loadHostResources() }

    func createVolume(pool: String, name: String, sizeGiB: Double, format: String) async -> StorageVolume? {
        let bytes = UInt64(max(0, sizeGiB) * 1024 * 1024 * 1024)
        do { return try await session.createVolume(pool: pool, name: name, capacityBytes: bytes, format: format) }
        catch { applyMessage = error.localizedDescription; return nil }
    }

    func fieldString(_ id: String, _ loc: FieldLocator) -> String { config?.fieldString(deviceID: id, loc) ?? "" }
    func fieldBool(_ id: String, _ loc: FieldLocator) -> Bool { config?.fieldBool(deviceID: id, loc) ?? false }
    func setField(_ id: String, _ loc: FieldLocator, string: String?) {
        config?.setField(deviceID: id, loc, string: string); touched()
    }
    func setField(_ id: String, _ loc: FieldLocator, bool: Bool) {
        config?.setField(deviceID: id, loc, bool: bool); touched()
    }
    func setInterfaceSource(_ id: String, type: String, source: String) {
        config?.setInterfaceSource(deviceID: id, type: type, source: source); touched()
    }
    func setDiskSource(_ id: String, path: String) {
        config?.setDiskSource(deviceID: id, path: path); touched()
    }

    var isLoaded: Bool { config != nil }

    func load() async {
        applyMessage = nil
        do {
            let xml = try await session.domainXML(uuid: uuid)
            config = try DomainConfig(xml: xml)
            devices = config?.deviceList() ?? []
            dirty = false
            loadError = nil
            await refreshConfigSyncState()
        } catch {
            loadError = error.localizedDescription
        }
    }

    func refreshConfigSyncState() async {
        guard isRunning else {
            liveDiffersFromSaved = false
            configChanges = []
            liveXML = nil
            persistentXML = nil
            return
        }
        do {
            let updated = try await session.domainIsUpdated(uuid: uuid)
            liveDiffersFromSaved = updated
            guard updated else {
                configChanges = []
                liveXML = nil
                persistentXML = nil
                return
            }
            let live = try await session.domainLiveXML(uuid: uuid)
            let saved = try await session.domainPersistentXML(uuid: uuid)
            liveXML = live
            persistentXML = saved
            configChanges = try DomainConfigDiff.changes(liveXML: live, savedXML: saved)
        } catch {
            liveDiffersFromSaved = false
            configChanges = []
            liveXML = nil
            persistentXML = nil
        }
    }

    /// Writes the running configuration to the saved definition (survives reboot).
    func syncSavedFromLive() async {
        guard let liveXML else { return }
        applying = true
        defer { applying = false }
        do {
            _ = try await session.defineXML(liveXML)
            applyMessage = "Saved configuration updated from the running VM."
            await refreshConfigSyncState()
            await load()
        } catch {
            applyMessage = error.localizedDescription
        }
    }

    func revert() { Task { await load() } }

    func apply() async {
        guard let config else { return }
        applying = true
        defer { applying = false }
        do {
            _ = try await session.defineXML(config.xmlString())
            applyMessage = "Applied. Changes take effect after the VM restarts."
            await load()
        } catch {
            applyMessage = error.localizedDescription
        }
    }

    var isRunning: Bool { session.domain(uuid: uuid)?.isActive == true }

    static func isHotpluggable(_ kind: DeviceKind) -> Bool {
        switch kind {
        case .disk, .cdrom, .interface, .hostdev, .redirdev: return true
        default: return false
        }
    }

    func attachDeviceLive(xml: String) async -> Bool {
        applying = true
        defer { applying = false }
        do {
            try await session.attachDevice(uuid: uuid, xml: xml, live: true, persistent: true)
            await load()
            applyMessage = "Device attached to the running VM."
            return true
        } catch {
            applyMessage = error.localizedDescription
            return false
        }
    }

    func detachDeviceLive(id: String) async -> Bool {
        guard let xml = config?.deviceXML(id: id) else { return false }
        applying = true
        defer { applying = false }
        do {
            try await session.detachDevice(uuid: uuid, xml: xml, live: true, persistent: true)
            await load()
            applyMessage = "Device detached from the running VM."
            return true
        } catch {
            applyMessage = error.localizedDescription
            return false
        }
    }

    func applyVcpusLive(_ count: Int) async {
        applying = true
        defer { applying = false }
        do {
            try await session.setVcpusLive(uuid: uuid, count: count)
            await load()
            applyMessage = "vCPU count changed on the running VM."
        } catch {
            applyMessage = error.localizedDescription
        }
    }

    func applyMemoryLive(currentMiB: Double) async {
        applying = true
        defer { applying = false }
        do {
            try await session.setMemoryLive(uuid: uuid, kib: UInt64(max(0, currentMiB) * 1024))
            await load()
            applyMessage = "Memory changed on the running VM."
        } catch {
            applyMessage = error.localizedDescription
        }
    }

    func addBlockReason(for kind: DeviceKind) -> String? { config?.addBlockReason(for: kind) }
    var graphicsTypes: Set<String> { config?.graphicsTypes ?? [] }
    var channelTargetNames: Set<String> { config?.channelTargetNames ?? [] }
    var inputPairs: Set<String> { config?.inputPairs ?? [] }

    func ejectCDROM(_ id: String) async {
        applying = true
        defer { applying = false }
        do {
            try await session.ejectCDROM(uuid: uuid, deviceID: id)
            config?.clearDiskSource(deviceID: id)
            devices = config?.deviceList() ?? []
            applyMessage = "Media ejected."
        } catch {
            applyMessage = error.localizedDescription
        }
    }

    private func touched() {
        devices = config?.deviceList() ?? []
        dirty = true
        applyMessage = nil
    }

    func setCPU(_ count: Int) { config?.vcpu = count; touched() }

    func setMemory(currentMiB: Double, maxMiB: Double) {
        config?.currentMemoryKiB = UInt64(max(0, currentMiB)) * 1024
        config?.memoryKiB = UInt64(max(0, maxMiB)) * 1024
        touched()
    }

    func setBootOrder(_ order: [String]) { config?.bootDevices = order; touched() }

    func addDevice(xml: String) {
        do { try config?.appendDeviceXML(xml); touched() }
        catch { applyMessage = error.localizedDescription }
    }

    func removeDevice(id: String) { config?.removeDevice(id: id); touched() }

    func setDeviceXML(id: String, _ xml: String) {
        do { try config?.setDeviceXML(id: id, xml); touched() }
        catch { applyMessage = error.localizedDescription }
    }

    func switchVideoToVirtio() {
        if let xml = config?.xmlSwitchingVideoToVirtio() {
            do { config = try DomainConfig(xml: xml); touched() }
            catch { applyMessage = error.localizedDescription }
        }
    }

    func disk(id: String) -> DiskInfo? { config?.disk(id: id) }
    func nic(id: String) -> NICInfo? { config?.nic(id: id) }
    func deviceXML(id: String) -> String? { config?.deviceXML(id: id) }
    func nextTargetDev(bus: String) -> String { config?.nextTargetDev(bus: bus) ?? "vdb" }

    var vcpu: Int { config?.vcpu ?? 1 }
    var currentMemoryMiB: Double { Double(config?.currentMemoryKiB ?? 0) / 1024 }
    var maxMemoryMiB: Double { Double(config?.memoryKiB ?? 0) / 1024 }
    var bootDevices: [String] { config?.bootDevices ?? [] }
    var videoModel: String? { config?.videoModel }

    var vmName: String { config?.name ?? "" }
    var title: String { config?.title ?? "" }
    func setTitle(_ s: String) { config?.title = s; touched() }
    var desc: String { config?.desc ?? "" }
    func setDescription(_ s: String) { config?.desc = s; touched() }
    var domainType: String { config?.domainType ?? "" }
    var arch: String { config?.arch ?? "" }
    var machine: String { config?.machine ?? "" }
    var emulator: String { config?.emulator ?? "" }
    var firmwareLabel: String { config?.firmwareLabel ?? "" }

    func loadAutostart() async -> Bool { (try? await session.autostart(uuid: uuid)) ?? false }
    func setAutostart(_ on: Bool) async -> Bool {
        (try? await session.setAutostart(uuid: uuid, on)) != nil
    }

    var cpuMode: String { config?.cpuMode ?? "" }
    func setCPUMode(_ m: String) { config?.cpuMode = m; touched() }
    var cpuModelName: String { config?.cpuModelName ?? "" }
    func setCPUModel(_ m: String) { config?.cpuModelName = m; touched() }
    var cpuTopology: (sockets: Int, cores: Int, threads: Int)? { config?.cpuTopology }
    func setCPUTopology(_ t: (sockets: Int, cores: Int, threads: Int)?) {
        config?.cpuTopology = t; touched()
    }

    var bootMenu: Bool { config?.bootMenu ?? false }
    func setBootMenu(_ b: Bool) { config?.bootMenu = b; touched() }
}