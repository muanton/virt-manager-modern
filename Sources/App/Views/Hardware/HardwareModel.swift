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

    private(set) var config: DomainConfig?
    let session: ConnectionSession
    let uuid: String

    init(session: ConnectionSession, uuid: String) {
        self.session = session
        self.uuid = uuid
    }

    // Host resources for the forms.
    var networks: [VirtNetwork] { session.networks }
    var volumes: [StorageVolume] { session.volumes }
    var usbDevices: [NodeDevice] { session.usbDevices }
    var pciDevices: [NodeDevice] { session.pciDevices }
    var storagePools: [String] { session.storagePools }
    func loadHostResources() async { await session.loadHostResources() }
    func createVolume(pool: String, name: String, sizeGiB: Double, format: String) async -> StorageVolume? {
        let bytes = UInt64(max(0, sizeGiB) * 1024 * 1024 * 1024)
        let v = await session.createVolume(pool: pool, name: name, capacityBytes: bytes, format: format)
        if v == nil { applyMessage = session.lastError }
        return v
    }

    // Schema-driven field access.
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
        guard let xml = await session.domainXML(uuid: uuid) else {
            loadError = session.lastError ?? "No XML returned"
            return
        }
        do {
            config = try DomainConfig(xml: xml)
            devices = config?.deviceList() ?? []
            dirty = false
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    func revert() { Task { await load() } }

    func apply() async {
        guard let config else { return }
        applying = true
        defer { applying = false }
        if await session.defineXML(config.xmlString()) {
            applyMessage = "Applied. Changes take effect after the VM restarts."
            await load()
        } else {
            applyMessage = session.lastError ?? "Failed to apply changes."
        }
    }

    // Add-rule queries (forwarded from the working copy so staged edits count).
    func addBlockReason(for kind: DeviceKind) -> String? { config?.addBlockReason(for: kind) }
    var graphicsTypes: Set<String> { config?.graphicsTypes ?? [] }
    var channelTargetNames: Set<String> { config?.channelTargetNames ?? [] }
    var inputPairs: Set<String> { config?.inputPairs ?? [] }

    /// Ejects CD-ROM media immediately (live + persistent via update-device,
    /// not the Apply path), then mirrors it in the working copy so other
    /// pending edits survive.
    func ejectCDROM(_ id: String) async {
        applying = true
        defer { applying = false }
        if await session.ejectCDROM(uuid: uuid, deviceID: id) {
            config?.clearDiskSource(deviceID: id)
            devices = config?.deviceList() ?? []
            applyMessage = "Media ejected."
        } else {
            applyMessage = session.lastError ?? "Failed to eject media."
        }
    }

    // MARK: - Mutations (all stage into the working copy)

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

    // Convenience reads for editors
    func disk(id: String) -> DiskInfo? { config?.disk(id: id) }
    func nic(id: String) -> NICInfo? { config?.nic(id: id) }
    func deviceXML(id: String) -> String? { config?.deviceXML(id: id) }
    func nextTargetDev(bus: String) -> String { config?.nextTargetDev(bus: bus) ?? "vdb" }

    var vcpu: Int { config?.vcpu ?? 1 }
    var currentMemoryMiB: Double { Double(config?.currentMemoryKiB ?? 0) / 1024 }
    var maxMemoryMiB: Double { Double(config?.memoryKiB ?? 0) / 1024 }
    var bootDevices: [String] { config?.bootDevices ?? [] }
    var videoModel: String? { config?.videoModel }

    // MARK: - General / metadata
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

    func loadAutostart() async -> Bool { await session.autostart(uuid: uuid) }
    func setAutostart(_ on: Bool) async -> Bool { await session.setAutostart(uuid: uuid, on) }

    // MARK: - CPU mode / topology
    var cpuMode: String { config?.cpuMode ?? "" }
    func setCPUMode(_ m: String) { config?.cpuMode = m; touched() }
    var cpuModelName: String { config?.cpuModelName ?? "" }
    func setCPUModel(_ m: String) { config?.cpuModelName = m; touched() }
    var cpuTopology: (sockets: Int, cores: Int, threads: Int)? { config?.cpuTopology }
    func setCPUTopology(_ t: (sockets: Int, cores: Int, threads: Int)?) {
        config?.cpuTopology = t; touched()
    }

    // MARK: - Boot menu
    var bootMenu: Bool { config?.bootMenu ?? false }
    func setBootMenu(_ b: Bool) { config?.bootMenu = b; touched() }
}
