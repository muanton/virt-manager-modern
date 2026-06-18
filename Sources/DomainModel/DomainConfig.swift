import Foundation

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespaces) }
}

public struct DiskInfo: Identifiable, Sendable {
    public let id = UUID()
    public var device: String      // disk, cdrom, floppy
    public var driverType: String? // qcow2, raw…
    public var source: String?     // file path or block dev
    public var target: String      // vda, sda…
    public var bus: String?        // virtio, sata, scsi…
}

public struct NICInfo: Identifiable, Sendable {
    public let id = UUID()
    public var type: String        // network, bridge, user…
    public var source: String?     // network name or bridge name
    public var model: String?      // virtio, e1000…
    public var mac: String?
}

/// Loads a libvirt domain XML document, exposes the commonly-edited fields as
/// typed properties, and serializes back to XML. Mutations are applied directly
/// onto the parsed `XMLDocument`, so elements we don't model are preserved.
public struct DomainConfig {
    private let doc: XMLDocument
    private var root: XMLElement { doc.rootElement()! }

    public init(xml: String) throws {
        self.doc = try XMLDocument(xmlString: xml, options: [.nodePreserveWhitespace])
        guard doc.rootElement()?.name == "domain" else {
            throw NSError(domain: "DomainConfig", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Not a libvirt domain XML document"])
        }
    }

    public func xmlString() -> String {
        doc.xmlString(options: [.nodePrettyPrint])
    }

    // MARK: - Identity

    public var name: String {
        root.elements(forName: "name").first?.stringValue ?? ""
    }

    // MARK: - CPU

    public var vcpu: Int {
        get { Int(root.elements(forName: "vcpu").first?.stringValue ?? "") ?? 1 }
        set { setElementText("vcpu", value: String(newValue)) }
    }

    // MARK: - Memory (always stored/exposed in KiB)

    public var memoryKiB: UInt64 {
        get { memoryValue("memory") }
        set { setMemory("memory", kiB: newValue) }
    }

    public var currentMemoryKiB: UInt64 {
        get { memoryValue("currentMemory") }
        set { setMemory("currentMemory", kiB: newValue) }
    }

    // MARK: - Boot order

    public var bootDevices: [String] {
        get {
            // os-level <boot dev='…'/> entries, if present…
            if let os = root.elements(forName: "os").first {
                let devs = os.elements(forName: "boot").compactMap {
                    $0.attribute(forName: "dev")?.stringValue
                }
                if !devs.isEmpty { return devs }
            }
            // …otherwise derive from per-device <boot order='N'/> (what the
            // New VM wizard writes), mapped to the equivalent device class.
            var ordered: [(Int, String)] = []
            for el in allDeviceElements() {
                guard let order = el.elements(forName: "boot").first?
                        .attribute(forName: "order")?.stringValue.flatMap(Int.init)
                else { continue }
                let dev: String?
                switch el.name {
                case "disk":
                    dev = el.attribute(forName: "device")?.stringValue == "cdrom" ? "cdrom" : "hd"
                case "interface": dev = "network"
                default: dev = nil
                }
                if let dev { ordered.append((order, dev)) }
            }
            return ordered.sorted { $0.0 < $1.0 }.map(\.1)
        }
        set {
            guard let os = root.elements(forName: "os").first else { return }
            // libvirt rejects mixing per-device <boot order> with os-level
            // <boot dev> — remove the per-device form before writing ours.
            for el in allDeviceElements() {
                for b in el.elements(forName: "boot") { el.removeChild(at: b.index) }
            }
            for old in os.elements(forName: "boot") { os.removeChild(at: old.index) }
            for dev in newValue {
                let e = XMLElement(name: "boot")
                e.addAttribute(XMLNode.attribute(withName: "dev", stringValue: dev) as! XMLNode)
                os.addChild(e)
            }
        }
    }

    private func allDeviceElements() -> [XMLElement] {
        root.elements(forName: "devices").first?.children?
            .compactMap { $0 as? XMLElement } ?? []
    }

    // MARK: - Read-only device inventory

    public var disks: [DiskInfo] {
        devices(named: "disk").map { d in
            DiskInfo(
                device: d.attribute(forName: "device")?.stringValue ?? "disk",
                driverType: d.elements(forName: "driver").first?.attribute(forName: "type")?.stringValue,
                source: d.elements(forName: "source").first.flatMap {
                    $0.attribute(forName: "file")?.stringValue
                        ?? $0.attribute(forName: "dev")?.stringValue
                        ?? $0.attribute(forName: "volume")?.stringValue
                },
                target: d.elements(forName: "target").first?.attribute(forName: "dev")?.stringValue ?? "?",
                bus: d.elements(forName: "target").first?.attribute(forName: "bus")?.stringValue)
        }
    }

    public var interfaces: [NICInfo] {
        devices(named: "interface").map { i in
            let src = i.elements(forName: "source").first
            return NICInfo(
                type: i.attribute(forName: "type")?.stringValue ?? "?",
                source: src?.attribute(forName: "network")?.stringValue
                    ?? src?.attribute(forName: "bridge")?.stringValue
                    ?? src?.attribute(forName: "dev")?.stringValue,
                model: i.elements(forName: "model").first?.attribute(forName: "type")?.stringValue,
                mac: i.elements(forName: "mac").first?.attribute(forName: "address")?.stringValue)
        }
    }

    public var graphics: GraphicsInfo? {
        guard let g = devices(named: "graphics").first else { return nil }
        let kind = GraphicsInfo.Kind(rawValue: g.attribute(forName: "type")?.stringValue ?? "") ?? .unknown
        let listen = g.attribute(forName: "listen")?.stringValue
            ?? g.elements(forName: "listen").first?.attribute(forName: "address")?.stringValue
        return GraphicsInfo(
            kind: kind,
            port: g.attribute(forName: "port")?.stringValue.flatMap(Int.init),
            tlsPort: g.attribute(forName: "tlsPort")?.stringValue.flatMap(Int.init),
            autoport: g.attribute(forName: "autoport")?.stringValue == "yes",
            listen: listen,
            password: g.attribute(forName: "passwd")?.stringValue,
            socketPath: g.attribute(forName: "socket")?.stringValue
                ?? g.elements(forName: "listen").first?.attribute(forName: "socket")?.stringValue)
    }

    // MARK: - Video device

    /// The primary video device's model type (e.g. "qxl", "virtio", "vga").
    public var videoModel: String? {
        primaryVideoModel()?.attribute(forName: "type")?.stringValue
    }

    /// Rewrites the primary video device to virtio-gpu (dropping qxl-only memory
    /// attributes) and returns the new XML. Returns nil if there's no video
    /// device. The mutation is applied to this config's document.
    public func xmlSwitchingVideoToVirtio() -> String? {
        guard let model = primaryVideoModel() else { return nil }
        if let t = model.attribute(forName: "type") {
            t.stringValue = "virtio"
        } else {
            model.addAttribute(XMLNode.attribute(withName: "type", stringValue: "virtio") as! XMLNode)
        }
        for attr in ["ram", "vram", "vram64", "vgamem"] {
            if model.attribute(forName: attr) != nil { model.removeAttribute(forName: attr) }
        }
        return xmlString()
    }

    private func primaryVideoModel() -> XMLElement? {
        let videos = devices(named: "video")
        let primary = videos.first {
            $0.elements(forName: "model").first?.attribute(forName: "primary")?.stringValue == "yes"
        } ?? videos.first
        return primary?.elements(forName: "model").first
    }

    // MARK: - General / metadata

    public var title: String {
        get { root.elements(forName: "title").first?.stringValue ?? "" }
        set { setElementText("title", value: newValue.isEmpty ? nil : newValue) }
    }
    public var desc: String {
        get { root.elements(forName: "description").first?.stringValue ?? "" }
        set { setElementText("description", value: newValue.isEmpty ? nil : newValue) }
    }

    public var domainType: String { root.attribute(forName: "type")?.stringValue ?? "qemu" }
    public var arch: String {
        osType()?.attribute(forName: "arch")?.stringValue ?? ""
    }
    public var machine: String {
        osType()?.attribute(forName: "machine")?.stringValue ?? ""
    }
    public var emulator: String {
        root.elements(forName: "devices").first?.elements(forName: "emulator").first?.stringValue ?? ""
    }
    public var firmwareLabel: String {
        let os = root.elements(forName: "os").first
        if os?.attribute(forName: "firmware")?.stringValue == "efi" { return "UEFI" }
        if os?.elements(forName: "loader").first != nil { return "UEFI" }
        return "BIOS"
    }

    private func osType() -> XMLElement? {
        root.elements(forName: "os").first?.elements(forName: "type").first
    }

    // MARK: - CPU mode / topology

    public var cpuMode: String {
        get { root.elements(forName: "cpu").first?.attribute(forName: "mode")?.stringValue ?? "" }
        set {
            let cpu = Self.childElement(root, "cpu", create: true)!
            Self.setAttr(cpu, "mode", newValue.isEmpty ? nil : newValue)
        }
    }
    public var cpuModelName: String {
        get { root.elements(forName: "cpu").first?.elements(forName: "model").first?.stringValue ?? "" }
        set {
            let cpu = Self.childElement(root, "cpu", create: true)!
            if newValue.isEmpty {
                if let m = cpu.elements(forName: "model").first { cpu.removeChild(at: m.index) }
            } else {
                Self.childElement(cpu, "model", create: true)!.stringValue = newValue
            }
        }
    }

    /// CPU topology (sockets, cores, threads); nil when unset.
    public var cpuTopology: (sockets: Int, cores: Int, threads: Int)? {
        get {
            guard let t = root.elements(forName: "cpu").first?.elements(forName: "topology").first
            else { return nil }
            func v(_ a: String) -> Int { Int(t.attribute(forName: a)?.stringValue ?? "") ?? 1 }
            return (v("sockets"), v("cores"), v("threads"))
        }
        set {
            let cpu = Self.childElement(root, "cpu", create: true)!
            if let topo = newValue {
                let t = Self.childElement(cpu, "topology", create: true)!
                Self.setAttr(t, "sockets", String(topo.sockets))
                Self.setAttr(t, "cores", String(topo.cores))
                Self.setAttr(t, "threads", String(topo.threads))
            } else if let t = cpu.elements(forName: "topology").first {
                cpu.removeChild(at: t.index)
            }
        }
    }

    // MARK: - Boot menu

    public var bootMenu: Bool {
        get { root.elements(forName: "os").first?.elements(forName: "bootmenu").first?
                .attribute(forName: "enable")?.stringValue == "yes" }
        set {
            guard let os = root.elements(forName: "os").first else { return }
            if newValue {
                Self.setAttr(Self.childElement(os, "bootmenu", create: true)!, "enable", "yes")
            } else if let bm = os.elements(forName: "bootmenu").first {
                os.removeChild(at: bm.index)
            }
        }
    }

    // MARK: - Generic device list / mutation

    /// All `<devices>` children as hardware-list rows, ordered and labelled like
    /// virt-manager (type rank, then document order). Display-only; the XML keeps
    /// every device.
    public func deviceList() -> [Device] {
        guard let devs = root.elements(forName: "devices").first else { return [] }
        var counts: [String: Int] = [:]        // positional id counters
        var diskBusIndex: [String: Int] = [:]  // per-bus disk numbering
        var redirIndex = 0
        var rows: [(rank: Int, doc: Int, device: Device)] = []
        var docIndex = 0

        for node in devs.children ?? [] {
            guard let el = node as? XMLElement, let name = el.name, name != "emulator" else { continue }
            let idx = counts[name, default: 0]
            counts[name] = idx + 1             // advance for every element so ids stay positional
            // Hidden like virt-manager: implicit controllers + memory balloon.
            if name == "memballoon" { continue }
            if name == "controller", Self.isHiddenController(el) { continue }

            let kind = Self.kind(for: el)
            let title = Self.label(for: el, kind: kind, diskBusIndex: &diskBusIndex, redirIndex: &redirIndex)
            rows.append((Self.typeRank(kind), docIndex,
                         Device(id: "\(name)-\(idx)", kind: kind, title: title,
                                subtitle: Self.subtitle(for: el, kind: kind),
                                removability: removability(of: el, kind: kind))))
            docIndex += 1
        }
        return rows.sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.doc < $1.doc }
            .map(\.device)
    }

    // MARK: - Removal rules

    /// What removing this device would do to the machine — virt-manager-style,
    /// but explicit: structural breakage is blocked, risky removals warn.
    private func removability(of el: XMLElement, kind: DeviceKind) -> Removability {
        let devs = allDeviceElements()
        switch kind {
        case .controller:
            let type = el.attribute(forName: "type")?.stringValue ?? ""
            if type == "pci" {
                return .blocked("Required by the machine type.")
            }
            let dependents = Self.dependentCount(onControllerType: type, in: devs)
            if dependents > 0 {
                let noun = dependents == 1 ? "device is" : "devices are"
                return .blocked("\(dependents) \(noun) attached to this \(type.uppercased()) controller. Remove them first.")
            }
            return .ok

        case .disk:
            // Boot disk: per-device <boot order>, os-level 'hd' entry, or the only disk.
            let dataDisks = devs.filter {
                $0.name == "disk" && $0.attribute(forName: "device")?.stringValue != "cdrom"
            }
            let hasPerDeviceBoot = !el.elements(forName: "boot").isEmpty
            if hasPerDeviceBoot || dataDisks.count == 1 {
                return .warning("This VM boots from this disk — it may not start afterwards.")
            }
            return .ok

        case .graphics:
            if devs.filter({ $0.name == "graphics" }).count == 1 {
                return .warning("This is the only display — you will lose the graphical console.")
            }
            return .ok

        case .video:
            if devs.filter({ $0.name == "video" }).count == 1,
               devs.contains(where: { $0.name == "graphics" }) {
                return .warning("This is the only video device — the display will have nothing to render on.")
            }
            return .ok

        case .interface:
            if devs.filter({ $0.name == "interface" }).count == 1 {
                return .warning("This is the only network interface — the VM will be offline.")
            }
            return .ok

        default:
            return .ok
        }
    }

    /// Devices that depend on a controller of `type` (coarse bus-type matching —
    /// fine for the single-controller-per-bus configs libvirt generates).
    private static func dependentCount(onControllerType type: String, in devs: [XMLElement]) -> Int {
        switch type {
        case "sata", "scsi", "ide":
            return devs.filter {
                $0.name == "disk" &&
                $0.elements(forName: "target").first?.attribute(forName: "bus")?.stringValue == type
            }.count
        case "usb":
            return devs.filter {
                ($0.name == "input" && $0.attribute(forName: "bus")?.stringValue == "usb")
                || ($0.name == "redirdev" && $0.attribute(forName: "bus")?.stringValue == "usb")
                || ($0.name == "hostdev" && $0.attribute(forName: "type")?.stringValue == "usb")
                || ($0.name == "disk" && $0.elements(forName: "target").first?
                        .attribute(forName: "bus")?.stringValue == "usb")
            }.count
        case "virtio-serial":
            return devs.filter {
                $0.name == "channel" &&
                $0.elements(forName: "target").first?.attribute(forName: "type")?.stringValue == "virtio"
            }.count
        default:
            return 0
        }
    }

    // MARK: - Add rules

    /// Reason a device of `kind` cannot be added right now, or nil if it can.
    /// Mirrors what libvirt/QEMU would reject (duplicates of singleton devices)
    /// plus functional dependencies (SPICE-only devices need a SPICE display).
    public func addBlockReason(for kind: DeviceKind) -> String? {
        let devs = allDeviceElements()
        func has(_ name: String) -> Bool { devs.contains { $0.name == name } }
        switch kind {
        case .memballoon where has("memballoon"):
            return "This VM already has a memory balloon (only one is allowed)."
        case .tpm where has("tpm"):
            return "This VM already has a TPM (only one is allowed)."
        case .watchdog where has("watchdog"):
            return "This VM already has a watchdog (only one is allowed)."
        case .redirdev, .smartcard:
            return hasSPICEGraphics ? nil
                 : "Requires a SPICE display — add one first."
        default:
            return nil
        }
    }

    public var hasSPICEGraphics: Bool {
        allDeviceElements().contains {
            $0.name == "graphics" && $0.attribute(forName: "type")?.stringValue == "spice"
        }
    }

    /// Graphics types already present ("spice", "vnc", …) — adding a second of
    /// the same type is rejected by QEMU.
    public var graphicsTypes: Set<String> {
        Set(allDeviceElements().filter { $0.name == "graphics" }
            .compactMap { $0.attribute(forName: "type")?.stringValue })
    }

    /// Channel target names already present (e.g. "com.redhat.spice.0").
    public var channelTargetNames: Set<String> {
        Set(allDeviceElements().filter { $0.name == "channel" }
            .compactMap { $0.elements(forName: "target").first?.attribute(forName: "name")?.stringValue })
    }

    /// "type/bus" pairs of existing input devices (e.g. "tablet/usb").
    public var inputPairs: Set<String> {
        Set(allDeviceElements().filter { $0.name == "input" }.map {
            "\($0.attribute(forName: "type")?.stringValue ?? "")/\($0.attribute(forName: "bus")?.stringValue ?? "")"
        })
    }

    private static func typeRank(_ kind: DeviceKind) -> Int {
        switch kind {
        case .disk, .cdrom: return 0
        case .interface: return 1
        case .input: return 2
        case .graphics: return 3
        case .sound: return 4
        case .serial: return 5
        case .console: return 6
        case .channel: return 7
        case .hostdev: return 8
        case .video: return 9
        case .watchdog: return 10
        case .controller: return 11
        case .filesystem: return 12
        case .smartcard: return 13
        case .redirdev: return 14
        case .tpm: return 15
        case .rng: return 16
        case .memballoon, .other: return 99
        }
    }

    private static let hiddenControllerModels: Set<String> = [
        "ich9-uhci1", "ich9-uhci2", "ich9-uhci3",
        "pcie-root-port", "pcie-to-pci-bridge", "dmi-to-pci-bridge", "pci-bridge",
    ]

    private static func isHiddenController(_ el: XMLElement) -> Bool {
        guard let model = el.attribute(forName: "model")?.stringValue else { return false }
        return hiddenControllerModels.contains(model)
    }

    public func deviceXML(id: String) -> String? {
        element(forDeviceID: id)?.xmlString(options: [.nodePrettyPrint])
    }

    public func setDeviceXML(id: String, _ xml: String) throws {
        guard let el = element(forDeviceID: id), let parent = el.parent as? XMLElement else {
            throw err("Device not found")
        }
        let newEl = try Self.parseDeviceElement(xml)
        let index = el.index
        parent.removeChild(at: index)
        parent.insertChild(newEl, at: index)
    }

    public func removeDevice(id: String) {
        guard let el = element(forDeviceID: id), let parent = el.parent as? XMLElement else { return }
        parent.removeChild(at: el.index)
    }

    public func appendDeviceXML(_ xml: String) throws {
        devicesElement().addChild(try Self.parseDeviceElement(xml))
    }

    /// Typed view of a specific disk / interface device, for the editors.
    public func disk(id: String) -> DiskInfo? {
        guard let d = element(forDeviceID: id) else { return nil }
        return DiskInfo(
            device: d.attribute(forName: "device")?.stringValue ?? "disk",
            driverType: d.elements(forName: "driver").first?.attribute(forName: "type")?.stringValue,
            source: d.elements(forName: "source").first.flatMap {
                $0.attribute(forName: "file")?.stringValue ?? $0.attribute(forName: "dev")?.stringValue
            },
            target: d.elements(forName: "target").first?.attribute(forName: "dev")?.stringValue ?? "?",
            bus: d.elements(forName: "target").first?.attribute(forName: "bus")?.stringValue)
    }

    public func nic(id: String) -> NICInfo? {
        guard let i = element(forDeviceID: id) else { return nil }
        let src = i.elements(forName: "source").first
        return NICInfo(
            type: i.attribute(forName: "type")?.stringValue ?? "network",
            source: src?.attribute(forName: "network")?.stringValue
                ?? src?.attribute(forName: "bridge")?.stringValue,
            model: i.elements(forName: "model").first?.attribute(forName: "type")?.stringValue,
            mac: i.elements(forName: "mac").first?.attribute(forName: "address")?.stringValue)
    }

    /// Next free disk target name for a bus (e.g. vdb, sdb).
    public func nextTargetDev(bus: String) -> String {
        let prefix = (bus == "sata" || bus == "scsi") ? "sd" : "vd"
        let used = Set(devices(named: "disk").compactMap {
            $0.elements(forName: "target").first?.attribute(forName: "dev")?.stringValue
        })
        for c in "abcdefghijklmnopqrstuvwxyz" where !used.contains("\(prefix)\(c)") {
            return "\(prefix)\(c)"
        }
        return "\(prefix)z"
    }

    // MARK: - Schema-driven field access

    public func fieldString(deviceID: String, _ loc: FieldLocator) -> String? {
        guard let el = element(forDeviceID: deviceID) else { return nil }
        switch loc {
        case .attr(let a): return el.attribute(forName: a)?.stringValue
        case .childAttr(let c, let a):
            return el.elements(forName: c).first?.attribute(forName: a)?.stringValue
        case .boolChild(let c): return el.elements(forName: c).first != nil ? "yes" : nil
        case .elementText(let c):
            return (c.flatMap { el.elements(forName: $0).first } ?? el).stringValue
        case .custom: return nil
        }
    }

    public func fieldBool(deviceID: String, _ loc: FieldLocator) -> Bool {
        guard let el = element(forDeviceID: deviceID) else { return false }
        if case .boolChild(let c) = loc { return el.elements(forName: c).first != nil }
        return fieldString(deviceID: deviceID, loc) != nil
    }

    public func setField(deviceID: String, _ loc: FieldLocator, string value: String?) {
        guard let el = element(forDeviceID: deviceID) else { return }
        switch loc {
        case .attr(let a): Self.setAttr(el, a, value)
        case .childAttr(let c, let a):
            if let value, !value.isEmpty {
                Self.setAttr(Self.childElement(el, c, create: true)!, a, value)
            } else if let child = el.elements(forName: c).first {
                child.removeAttribute(forName: a)
                if (child.attributes ?? []).isEmpty && (child.children ?? []).isEmpty {
                    el.removeChild(at: child.index)
                }
            }
        case .elementText(let c):
            let target = c.map { Self.childElement(el, $0, create: true)! } ?? el
            target.stringValue = value
        case .boolChild, .custom: break
        }
    }

    public func setField(deviceID: String, _ loc: FieldLocator, bool: Bool) {
        guard let el = element(forDeviceID: deviceID), case .boolChild(let c) = loc else { return }
        if bool {
            if el.elements(forName: c).first == nil { el.addChild(XMLElement(name: c)) }
        } else {
            for x in el.elements(forName: c) { el.removeChild(at: x.index) }
        }
    }

    /// Sets a NIC's source to a virtual network or a bridge.
    public func setInterfaceSource(deviceID: String, type: String, source: String) {
        guard let el = element(forDeviceID: deviceID) else { return }
        Self.setAttr(el, "type", type)
        for s in el.elements(forName: "source") { el.removeChild(at: s.index) }
        let s = XMLElement(name: "source")
        Self.setAttr(s, type == "bridge" ? "bridge" : "network", source)
        el.insertChild(s, at: 0)
    }

    /// XML for a clone of this domain: new name, fresh UUID, MACs stripped
    /// (libvirt regenerates), per-VM NVRAM dropped (regenerated from the
    /// firmware template), and disk sources remapped per `diskPathMap`
    /// (old path → new path; unmapped disks keep their source = shared).
    public func xmlForClone(newName: String, diskPathMap: [String: String]) -> String {
        let copy = root.copy() as! XMLElement

        func setChildText(_ name: String, _ value: String) {
            for old in copy.elements(forName: name) { copy.removeChild(at: old.index) }
            let el = XMLElement(name: name)
            el.stringValue = value
            copy.insertChild(el, at: 0)
        }
        setChildText("uuid", UUID().uuidString.lowercased())
        setChildText("name", newName)

        // NVRAM is per-VM state — two clones must not share the file.
        for os in copy.elements(forName: "os") {
            for nv in os.elements(forName: "nvram") { os.removeChild(at: nv.index) }
        }

        if let devs = copy.elements(forName: "devices").first {
            for el in devs.children?.compactMap({ $0 as? XMLElement }) ?? [] {
                if el.name == "interface" {
                    for mac in el.elements(forName: "mac") { el.removeChild(at: mac.index) }
                }
                if el.name == "disk", let src = el.elements(forName: "source").first,
                   let file = src.attribute(forName: "file")?.stringValue,
                   let newPath = diskPathMap[file] {
                    if newPath.isEmpty {
                        el.removeChild(at: src.index)   // skip → empty drive
                    } else {
                        src.attribute(forName: "file")?.stringValue = newPath
                    }
                }
            }
        }
        return copy.xmlString(options: [.nodePrettyPrint])
    }

    /// Sets a disk's backing file path.
    public func setDiskSource(deviceID: String, path: String) {
        guard let el = element(forDeviceID: deviceID) else { return }
        Self.setAttr(el, "type", "file")
        let s = Self.childElement(el, "source", create: true)!
        s.removeAttribute(forName: "dev")
        s.removeAttribute(forName: "volume")
        Self.setAttr(s, "file", path)
    }

    /// Removes a disk's media (`<source>`) in the working copy — ejecting a
    /// CD-ROM. The drive itself stays attached.
    public func clearDiskSource(deviceID: String) {
        guard let el = element(forDeviceID: deviceID) else { return }
        for s in el.elements(forName: "source") { el.removeChild(at: s.index) }
    }

    /// Device XML for one CD-ROM with its media removed — passing this to
    /// libvirt's update-device ejects the disc. Nil if the device isn't a
    /// CD-ROM or already has no media.
    public func cdromEjectXML(deviceID: String) -> String? {
        guard let el = element(forDeviceID: deviceID),
              el.name == "disk",
              el.attribute(forName: "device")?.stringValue == "cdrom",
              !el.elements(forName: "source").isEmpty,
              let copy = el.copy() as? XMLElement else { return nil }
        for s in copy.elements(forName: "source") { copy.removeChild(at: s.index) }
        return copy.xmlString
    }

    /// Eject XML for every CD-ROM that currently has media.
    public func cdromEjectXMLs() -> [String] {
        deviceList().compactMap { cdromEjectXML(deviceID: $0.id) }
    }

    private static func setAttr(_ el: XMLElement, _ name: String, _ value: String?) {
        if let value, !value.isEmpty {
            if let a = el.attribute(forName: name) { a.stringValue = value }
            else { el.addAttribute(XMLNode.attribute(withName: name, stringValue: value) as! XMLNode) }
        } else if el.attribute(forName: name) != nil {
            el.removeAttribute(forName: name)
        }
    }

    private static func childElement(_ el: XMLElement, _ name: String, create: Bool) -> XMLElement? {
        if let c = el.elements(forName: name).first { return c }
        guard create else { return nil }
        let c = XMLElement(name: name)
        el.addChild(c)
        return c
    }

    private func element(forDeviceID id: String) -> XMLElement? {
        guard let dash = id.lastIndex(of: "-"), let idx = Int(id[id.index(after: dash)...]) else { return nil }
        let name = String(id[..<dash])
        let matching = devices(named: name)
        return (idx >= 0 && idx < matching.count) ? matching[idx] : nil
    }

    private func devicesElement() -> XMLElement {
        if let d = root.elements(forName: "devices").first { return d }
        let d = XMLElement(name: "devices")
        root.addChild(d)
        return d
    }

    private static func parseDeviceElement(_ xml: String) throws -> XMLElement {
        let d = try XMLDocument(xmlString: xml, options: [.nodePreserveWhitespace])
        guard let r = d.rootElement(), let copy = r.copy() as? XMLElement else {
            throw NSError(domain: "DomainConfig", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid device XML"])
        }
        return copy
    }

    private func err(_ msg: String) -> NSError {
        NSError(domain: "DomainConfig", code: 2, userInfo: [NSLocalizedDescriptionKey: msg])
    }

    private static func kind(for el: XMLElement) -> DeviceKind {
        switch el.name ?? "" {
        case "disk":
            return el.attribute(forName: "device")?.stringValue == "cdrom" ? .cdrom : .disk
        case "interface": return .interface
        case "graphics": return .graphics
        case "video": return .video
        case "controller": return .controller
        case "sound": return .sound
        case "input": return .input
        case "channel": return .channel
        case "serial": return .serial
        case "console": return .console
        case "hostdev": return .hostdev
        case "redirdev": return .redirdev
        case "tpm": return .tpm
        case "rng": return .rng
        case "memballoon": return .memballoon
        case "watchdog": return .watchdog
        case "filesystem": return .filesystem
        case "smartcard": return .smartcard
        case let other: return .other(other)
        }
    }

    /// virt-manager-style device label (see `_label_for_device`).
    private static func label(for el: XMLElement, kind: DeviceKind,
                              diskBusIndex: inout [String: Int], redirIndex: inout Int) -> String {
        func childAttr(_ c: String, _ a: String) -> String? {
            el.elements(forName: c).first?.attribute(forName: a)?.stringValue
        }
        switch kind {
        case .disk, .cdrom:
            let bus = childAttr("target", "bus") ?? ""
            let n = (diskBusIndex[bus, default: 0]) + 1
            diskBusIndex[bus] = n
            let busP = busPretty(bus)
            let device = el.attribute(forName: "device")?.stringValue ?? "disk"
            switch device {
            case "cdrom": return "\(busP) CDROM \(n)".trimmed
            case "floppy": return "Floppy \(n)"
            case "disk": return "\(busP) Disk \(n)".trimmed
            default: return "\(busP) \(device.capitalized) \(n)".trimmed
            }
        case .interface:
            let mac = childAttr("mac", "address") ?? ""
            return "NIC \(String(mac.suffix(9)))"
        case .input:
            switch el.attribute(forName: "type")?.stringValue {
            case "tablet": return "Tablet"
            case "mouse": return "Mouse"
            case "keyboard": return "Keyboard"
            default: return "Input"
            }
        case .graphics:
            let t = el.attribute(forName: "type")?.stringValue ?? ""
            let pretty = (t == "vnc" || t == "rdp" || t == "sdl") ? t.uppercased() : t.capitalized
            return "Display \(pretty)"
        case .sound:
            return "Sound \(el.attribute(forName: "model")?.stringValue ?? "")".trimmed
        case .serial:
            return "Serial \((Int(childAttr("target", "port") ?? "") ?? 0) + 1)"
        case .console:
            return "Console \((Int(childAttr("target", "port") ?? "") ?? 0) + 1)"
        case .channel:
            if let name = channelName(childAttr("target", "name")) { return "Channel (\(name))" }
            return "Channel \(el.attribute(forName: "type")?.stringValue ?? "")".trimmed
        case .video:
            return "Video \(videoPretty(childAttr("model", "type") ?? ""))".trimmed
        case .watchdog: return "Watchdog"
        case .filesystem: return "Filesystem \(childAttr("target", "dir") ?? "")".trimmed
        case .smartcard: return "Smartcard"
        case .tpm: return "TPM"
        case .redirdev:
            redirIndex += 1
            return "\(busPretty(el.attribute(forName: "bus")?.stringValue ?? "usb")) Redirector \(redirIndex)"
        case .controller:
            let desc = controllerDesc(type: el.attribute(forName: "type")?.stringValue ?? "",
                                      model: el.attribute(forName: "model")?.stringValue)
            if let idx = el.attribute(forName: "index")?.stringValue { return "Controller \(desc) \(idx)" }
            return "Controller \(desc)"
        case .rng:
            let dev = el.elements(forName: "backend").first?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return dev.isEmpty ? "RNG" : "RNG \(dev)"
        case .hostdev:
            return el.attribute(forName: "type")?.stringValue == "pci" ? "PCI Host Device" : "USB Host Device"
        case .memballoon, .other:
            return kind.label
        }
    }

    private static func busPretty(_ bus: String) -> String {
        switch bus {
        case "ide": return "IDE"; case "nvme": return "NVMe"; case "sata": return "SATA"
        case "scsi": return "SCSI"; case "sd": return "SD"; case "usb": return "USB"
        case "virtio": return "VirtIO"; case "xen": return "Xen"; default: return bus
        }
    }

    private static func channelName(_ target: String?) -> String? {
        switch target {
        case "com.redhat.spice.0": return "spice"
        case "org.qemu.guest_agent.0": return "qemu-ga"
        case "org.libguestfs.channel.0": return "libguestfs"
        case "org.spice-space.webdav.0": return "spice-webdav"
        default: return target?.isEmpty == false ? target : nil
        }
    }

    private static func videoPretty(_ model: String) -> String {
        ["qxl", "vga", "vmvga"].contains(model) ? model.uppercased() : model.capitalized
    }

    private static func controllerDesc(type: String, model: String?) -> String {
        if type == "scsi", model == "virtio-scsi" { return "VirtIO SCSI" }
        if type == "pci", model == "pcie-root" { return "PCIe" }
        switch type {
        case "usb": return "USB"; case "sata": return "SATA"; case "ide": return "IDE"
        case "scsi": return "SCSI"; case "pci": return "PCI"; case "ccid": return "CCID"
        case "virtio-serial": return "VirtIO Serial"; default: return type.uppercased()
        }
    }

    private static func subtitle(for el: XMLElement, kind: DeviceKind) -> String {
        switch kind {
        case .disk, .cdrom:
            let src = el.elements(forName: "source").first
            return src?.attribute(forName: "file")?.stringValue
                ?? src?.attribute(forName: "dev")?.stringValue
                ?? src?.attribute(forName: "volume")?.stringValue
                ?? (kind == .cdrom ? "(empty)" : "")
        case .interface:
            let src = el.elements(forName: "source").first
            let net = src?.attribute(forName: "network")?.stringValue
            let br = src?.attribute(forName: "bridge")?.stringValue
            let s = net.map { "network: \($0)" } ?? br.map { "bridge: \($0)" } ?? ""
            let mac = el.elements(forName: "mac").first?.attribute(forName: "address")?.stringValue ?? ""
            return [s, mac].filter { !$0.isEmpty }.joined(separator: " · ")
        case .graphics:
            let listen = el.attribute(forName: "listen")?.stringValue
                ?? el.elements(forName: "listen").first?.attribute(forName: "address")?.stringValue ?? ""
            let port = el.attribute(forName: "port")?.stringValue ?? ""
            return [listen, port].filter { !$0.isEmpty }.joined(separator: ":")
        case .controller:
            let type = el.attribute(forName: "type")?.stringValue ?? ""
            if let idx = el.attribute(forName: "index")?.stringValue { return "\(type) · index \(idx)" }
            return type
        case .redirdev:
            return el.attribute(forName: "type")?.stringValue ?? ""
        case .channel:
            return el.elements(forName: "target").first?.attribute(forName: "name")?.stringValue ?? ""
        default:
            return ""
        }
    }

    // MARK: - Helpers

    private func devices(named name: String) -> [XMLElement] {
        root.elements(forName: "devices").first?.elements(forName: name) ?? []
    }

    private func setElementText(_ name: String, value: String?) {
        if let value {
            if let e = root.elements(forName: name).first { e.stringValue = value }
            else { root.addChild(XMLElement(name: name, stringValue: value)) }
        } else if let e = root.elements(forName: name).first {
            root.removeChild(at: e.index)
        }
    }

    private func memoryValue(_ name: String) -> UInt64 {
        guard let e = root.elements(forName: name).first,
              let raw = e.stringValue, let v = UInt64(raw) else { return 0 }
        let unit = e.attribute(forName: "unit")?.stringValue ?? "KiB"
        return Self.toKiB(v, unit: unit)
    }

    private func setMemory(_ name: String, kiB: UInt64) {
        let e: XMLElement
        if let existing = root.elements(forName: name).first {
            e = existing
        } else {
            e = XMLElement(name: name)
            root.addChild(e)
        }
        e.stringValue = String(kiB)
        if let attr = e.attribute(forName: "unit") {
            attr.stringValue = "KiB"
        } else {
            e.addAttribute(XMLNode.attribute(withName: "unit", stringValue: "KiB") as! XMLNode)
        }
    }

    private static func toKiB(_ value: UInt64, unit: String) -> UInt64 {
        switch unit.lowercased() {
        case "b", "bytes":        return value / 1024
        case "k", "kb":           return value * 1000 / 1024
        case "kib":               return value
        case "m", "mb":           return value * 1_000_000 / 1024
        case "mib":               return value * 1024
        case "g", "gb":           return value * 1_000_000_000 / 1024
        case "gib":               return value * 1024 * 1024
        case "t", "tb":           return value * 1_000_000_000_000 / 1024
        case "tib":               return value * 1024 * 1024 * 1024
        default:                  return value
        }
    }

    // MARK: - Live vs saved diff

    /// Normalized device descriptions for comparing running and persistent XML.
    public func deviceDiffSignatures() -> Set<String> {
        guard let devs = root.elements(forName: "devices").first else { return [] }
        var out: Set<String> = []
        for node in devs.children ?? [] {
            guard let el = node as? XMLElement, let name = el.name, name != "emulator" else { continue }
            if name == "memballoon" { continue }
            if name == "controller", Self.isHiddenController(el) { continue }
            if let sig = Self.deviceDiffSignature(el) { out.insert(sig) }
        }
        return out
    }

    private static func deviceDiffSignature(_ el: XMLElement) -> String? {
        guard let name = el.name else { return nil }
        switch name {
        case "disk":
            let dev = el.attribute(forName: "device")?.stringValue ?? "disk"
            let target = el.elements(forName: "target").first
            let tdev = target?.attribute(forName: "dev")?.stringValue ?? "?"
            let bus = target?.attribute(forName: "bus")?.stringValue ?? ""
            let src = el.elements(forName: "source").first
            let path = src?.attribute(forName: "file")?.stringValue
                ?? src?.attribute(forName: "dev")?.stringValue
                ?? src?.attribute(forName: "volume")?.stringValue ?? ""
            return "Disk (\(dev), \(bus)/\(tdev)): \(path.isEmpty ? "empty" : path)"
        case "interface":
            let type = el.attribute(forName: "type")?.stringValue ?? "?"
            let src = el.elements(forName: "source").first
            let source = src?.attribute(forName: "network")?.stringValue
                ?? src?.attribute(forName: "bridge")?.stringValue
                ?? src?.attribute(forName: "dev")?.stringValue ?? "?"
            let model = el.elements(forName: "model").first?
                .attribute(forName: "type")?.stringValue ?? "?"
            return "NIC (\(type), \(model)): \(source)"
        case "hostdev":
            let type = el.attribute(forName: "type")?.stringValue ?? "?"
            let src = el.elements(forName: "source").first
            if let bus = src?.elements(forName: "address").first {
                let domain = bus.attribute(forName: "domain")?.stringValue ?? "0"
                let slot = bus.attribute(forName: "slot")?.stringValue ?? "0"
                let func_ = bus.attribute(forName: "function")?.stringValue ?? "0"
                return "Host device (\(type)): \(domain):\(slot).\(func_)"
            }
            return "Host device (\(type))"
        case "redirdev":
            let bus = el.attribute(forName: "bus")?.stringValue ?? "?"
            let type = el.attribute(forName: "type")?.stringValue ?? "?"
            return "USB redirection (\(bus), \(type))"
        default:
            return "\(kind(for: el).label): \(compactDeviceXML(el))"
        }
    }

    private static func compactDeviceXML(_ el: XMLElement) -> String {
        let copy = el.copy() as! XMLElement
        stripVolatileDeviceNodes(copy)
        return copy.xmlString(options: [])
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private static func stripVolatileDeviceNodes(_ el: XMLElement) {
        let volatile = Set(["address", "alias", "boot"])
        for child in (el.children ?? []).reversed() {
            guard let c = child as? XMLElement, let n = c.name else { continue }
            if volatile.contains(n) {
                el.removeChild(at: c.index)
            } else {
                stripVolatileDeviceNodes(c)
            }
        }
    }
}
