import CLibvirt
import Foundation

// MARK: - Value types

public struct VirtNetwork: Identifiable, Sendable, Hashable {
    public let name: String
    public let bridge: String?
    public let active: Bool
    public let persistent: Bool
    public var id: String { name }
}

public struct StoragePoolInfo: Identifiable, Sendable, Hashable {
    public let name: String
    public let active: Bool
    public let capacityBytes: UInt64
    public let allocationBytes: UInt64
    public let availableBytes: UInt64
    public var id: String { name }
}

public struct StorageVolume: Identifiable, Sendable, Hashable {
    public let pool: String
    public let name: String
    public let path: String
    public let capacityBytes: UInt64
    public let format: String?
    public var id: String { path }
}

public struct DomainCaps: Sendable, Hashable {
    public let domainType: String   // kvm | qemu
    public let emulator: String
    public let arch: String
    public let machine: String
    public let firmwareEFI: Bool

    public static let fallback = DomainCaps(
        domainType: "kvm", emulator: "/usr/bin/qemu-system-x86_64",
        arch: "x86_64", machine: "q35", firmwareEFI: true)
}

public enum NodeDeviceKind: String, Sendable, Hashable { case usb, pci }

public struct NodeDevice: Identifiable, Sendable, Hashable {
    public let id: String        // libvirt node-device name
    public let kind: NodeDeviceKind
    public let label: String
    public let vendorID: String?
    public let productID: String?
    public let usbBus: Int?
    public let usbDevice: Int?
    public let pciDomain: Int?
    public let pciBus: Int?
    public let pciSlot: Int?
    public let pciFunction: Int?

    /// A `<hostdev>` element targeting this host device.
    public func hostdevXML() -> String {
        switch kind {
        case .usb:
            return """
            <hostdev mode='subsystem' type='usb' managed='yes'>
              <source>
                <vendor id='\(vendorID ?? "0x0000")'/>
                <product id='\(productID ?? "0x0000")'/>
              </source>
            </hostdev>
            """
        case .pci:
            let d = String(format: "0x%04x", pciDomain ?? 0)
            let b = String(format: "0x%02x", pciBus ?? 0)
            let s = String(format: "0x%02x", pciSlot ?? 0)
            let f = String(format: "0x%x", pciFunction ?? 0)
            return """
            <hostdev mode='subsystem' type='pci' managed='yes'>
              <source>
                <address domain='\(d)' bus='\(b)' slot='\(s)' function='\(f)'/>
              </source>
            </hostdev>
            """
        }
    }
}

// MARK: - Queries

extension LibvirtConnection {
    /// A minimal NAT network suitable for most QEMU/KVM guests.
    public static let defaultNATNetworkXML = """
    <network>
      <name>default</name>
      <bridge name='virbr0' stp='on' delay='0'/>
      <forward mode='nat'/>
      <ip address='192.168.122.1' netmask='255.255.255.0'>
        <dhcp>
          <range start='192.168.122.2' end='192.168.122.254'/>
        </dhcp>
      </ip>
    </network>
    """

    public func listNetworks() async throws -> [VirtNetwork] {
        try await run { conn in
            var array: UnsafeMutablePointer<OpaquePointer?>?
            let count = virConnectListAllNetworks(conn, &array, 0)
            guard count >= 0, let array else {
                throw LibvirtError.lastError(fallback: "Failed to list networks")
            }
            defer { free(array) }
            var out: [VirtNetwork] = []
            for i in 0..<Int(count) {
                guard let net = array[i] else { continue }
                defer { virNetworkFree(net) }
                let name = virNetworkGetName(net).map { String(cString: $0) } ?? "?"
                var bridge: String?
                if let b = virNetworkGetBridgeName(net) { bridge = String(cString: b); free(b) }
                out.append(VirtNetwork(name: name, bridge: bridge,
                                       active: virNetworkIsActive(net) == 1,
                                       persistent: virNetworkIsPersistent(net) == 1))
            }
            return out.sorted { $0.name < $1.name }
        }
    }

    public func listStoragePools() async throws -> [StoragePoolInfo] {
        try await run { conn in
            var pools: UnsafeMutablePointer<OpaquePointer?>?
            let count = virConnectListAllStoragePools(conn, &pools, 0)
            guard count >= 0, let pools else {
                throw LibvirtError.lastError(fallback: "Failed to list storage pools")
            }
            defer { free(pools) }

            var out: [StoragePoolInfo] = []
            for i in 0..<Int(count) {
                guard let pool = pools[i] else { continue }
                defer { virStoragePoolFree(pool) }
                let name = virStoragePoolGetName(pool).map { String(cString: $0) } ?? "?"
                var info = virStoragePoolInfo()
                let ok = virStoragePoolGetInfo(pool, &info) == 0
                out.append(StoragePoolInfo(
                    name: name,
                    active: virStoragePoolIsActive(pool) == 1,
                    capacityBytes: ok ? UInt64(info.capacity) : 0,
                    allocationBytes: ok ? UInt64(info.allocation) : 0,
                    availableBytes: ok ? UInt64(info.available) : 0))
            }
            return out.sorted { $0.name < $1.name }
        }
    }

    public func setStoragePoolActive(name: String, active: Bool) async throws {
        try await run { conn in
            guard let pool = virStoragePoolLookupByName(conn, name) else {
                throw LibvirtError.lastError(fallback: "Storage pool \(name) not found")
            }
            defer { virStoragePoolFree(pool) }
            let rc: Int32
            if active {
                rc = virStoragePoolCreate(pool, 0)
            } else {
                rc = virStoragePoolDestroy(pool)
            }
            guard rc == 0 else {
                throw LibvirtError.lastError(fallback: active
                    ? "Failed to start pool \(name)" : "Failed to stop pool \(name)")
            }
        }
    }

    public func refreshStoragePool(name: String) async throws {
        try await run { conn in
            guard let pool = virStoragePoolLookupByName(conn, name) else {
                throw LibvirtError.lastError(fallback: "Storage pool \(name) not found")
            }
            defer { virStoragePoolFree(pool) }
            let rc: Int32
            if virStoragePoolIsActive(pool) == 1 {
                rc = virStoragePoolRefresh(pool, 0)
            } else {
                rc = virStoragePoolBuild(pool, 0)
            }
            guard rc == 0 else {
                throw LibvirtError.lastError(fallback: "Failed to refresh pool \(name)")
            }
        }
    }

    public func listVolumes() async throws -> [StorageVolume] {
        try await run { conn in
            var pools: UnsafeMutablePointer<OpaquePointer?>?
            let pcount = virConnectListAllStoragePools(conn, &pools, 0)
            guard pcount >= 0, let pools else {
                throw LibvirtError.lastError(fallback: "Failed to list storage pools")
            }
            defer { free(pools) }

            var out: [StorageVolume] = []
            for i in 0..<Int(pcount) {
                guard let pool = pools[i] else { continue }
                defer { virStoragePoolFree(pool) }
                let poolName = virStoragePoolGetName(pool).map { String(cString: $0) } ?? "?"

                var vols: UnsafeMutablePointer<OpaquePointer?>?
                let vcount = virStoragePoolListAllVolumes(pool, &vols, 0)
                guard vcount >= 0, let vols else { continue }
                defer { free(vols) }
                for j in 0..<Int(vcount) {
                    guard let vol = vols[j] else { continue }
                    defer { virStorageVolFree(vol) }
                    let name = virStorageVolGetName(vol).map { String(cString: $0) } ?? "?"
                    var path = ""
                    if let p = virStorageVolGetPath(vol) { path = String(cString: p); free(p) }
                    var info = virStorageVolInfo()
                    let cap = virStorageVolGetInfo(vol, &info) == 0 ? UInt64(info.capacity) : 0
                    var format: String?
                    if let x = virStorageVolGetXMLDesc(vol, 0) {
                        let xml = String(cString: x); free(x)
                        format = Self.formatFromVolumeXML(xml)
                    }
                    out.append(StorageVolume(pool: poolName, name: name, path: path,
                                             capacityBytes: cap, format: format))
                }
            }
            return out.sorted { $0.name < $1.name }
        }
    }

    public func resizeVolume(path: String, capacityBytes: UInt64) async throws {
        try await run { conn in
            guard let vol = virStorageVolLookupByPath(conn, path) else {
                throw LibvirtError.lastError(fallback: "\(path) is not managed by a storage pool")
            }
            defer { virStorageVolFree(vol) }
            let flags = VIR_STORAGE_VOL_RESIZE_ALLOCATE.rawValue
            guard virStorageVolResize(vol, capacityBytes, flags) == 0 else {
                throw LibvirtError.lastError(fallback: "Failed to resize volume")
            }
        }
    }

    public func wipeVolume(path: String) async throws {
        try await run { conn in
            guard let vol = virStorageVolLookupByPath(conn, path) else {
                throw LibvirtError.lastError(fallback: "\(path) is not managed by a storage pool")
            }
            defer { virStorageVolFree(vol) }
            guard virStorageVolWipe(vol, 0) == 0 else {
                throw LibvirtError.lastError(fallback: "Failed to wipe volume")
            }
        }
    }

    public func createVolume(pool poolName: String, name: String,
                             capacityBytes: UInt64, format: String) async throws -> StorageVolume {
        try await run { conn in
            guard let pool = virStoragePoolLookupByName(conn, poolName) else {
                throw LibvirtError.lastError(fallback: "Storage pool not found")
            }
            defer { virStoragePoolFree(pool) }
            let fileName = name.hasSuffix(".\(format)") || format == "raw" ? name : "\(name).\(format)"
            let xml = """
            <volume>
              <name>\(fileName)</name>
              <capacity unit='bytes'>\(capacityBytes)</capacity>
              <target><format type='\(format)'/></target>
            </volume>
            """
            guard let vol = virStorageVolCreateXML(pool, xml, 0) else {
                throw LibvirtError.lastError(fallback: "Failed to create volume")
            }
            defer { virStorageVolFree(vol) }
            var path = ""
            if let p = virStorageVolGetPath(vol) { path = String(cString: p); free(p) }
            return StorageVolume(pool: poolName, name: fileName, path: path,
                                 capacityBytes: capacityBytes, format: format)
        }
    }

    public func listNodeDevices(kind: NodeDeviceKind) async throws -> [NodeDevice] {
        try await run { conn in
            var array: UnsafeMutablePointer<OpaquePointer?>?
            let count = virConnectListAllNodeDevices(conn, &array, 0)
            guard count >= 0, let array else {
                throw LibvirtError.lastError(fallback: "Failed to list host devices")
            }
            defer { free(array) }
            var out: [NodeDevice] = []
            for i in 0..<Int(count) {
                guard let dev = array[i] else { continue }
                defer { virNodeDeviceFree(dev) }
                let name = virNodeDeviceGetName(dev).map { String(cString: $0) } ?? "?"
                guard let x = virNodeDeviceGetXMLDesc(dev, 0) else { continue }
                let xml = String(cString: x); free(x)
                if let nd = Self.parseNodeDevice(name: name, xml: xml, kind: kind) {
                    out.append(nd)
                }
            }
            return out.sorted { $0.label < $1.label }
        }
    }

    public func networkXML(name: String) async throws -> String {
        try await run { conn in
            guard let net = virNetworkLookupByName(conn, name) else {
                throw LibvirtError.lastError(fallback: "Network \(name) not found")
            }
            defer { virNetworkFree(net) }
            guard let x = virNetworkGetXMLDesc(net, 0) else {
                throw LibvirtError.lastError(fallback: "Failed to read network XML")
            }
            defer { free(x) }
            return String(cString: x)
        }
    }

    public func defineNetwork(xml: String) async throws -> VirtNetwork {
        try await run { conn in
            guard let net = virNetworkDefineXML(conn, xml) else {
                throw LibvirtError.lastError(fallback: "Failed to define network")
            }
            defer { virNetworkFree(net) }
            return Self.networkSummary(net)
        }
    }

    public func setNetworkActive(name: String, active: Bool) async throws {
        try await run { conn in
            guard let net = virNetworkLookupByName(conn, name) else {
                throw LibvirtError.lastError(fallback: "Network \(name) not found")
            }
            defer { virNetworkFree(net) }
            let rc: Int32
            if active {
                rc = virNetworkIsActive(net) == 1 ? 0 : virNetworkCreate(net)
            } else {
                rc = virNetworkIsActive(net) == 1 ? virNetworkDestroy(net) : 0
            }
            guard rc == 0 else {
                throw LibvirtError.lastError(fallback: active
                    ? "Failed to start network \(name)" : "Failed to stop network \(name)")
            }
        }
    }

    public func undefineNetwork(name: String) async throws {
        try await run { conn in
            guard let net = virNetworkLookupByName(conn, name) else {
                throw LibvirtError.lastError(fallback: "Network \(name) not found")
            }
            defer { virNetworkFree(net) }
            if virNetworkIsActive(net) == 1 {
                guard virNetworkDestroy(net) == 0 else {
                    throw LibvirtError.lastError(fallback: "Failed to stop network \(name)")
                }
            }
            guard virNetworkUndefine(net) == 0 else {
                throw LibvirtError.lastError(fallback: "Failed to undefine network \(name)")
            }
        }
    }

    private static func networkSummary(_ net: OpaquePointer) -> VirtNetwork {
        let name = virNetworkGetName(net).map { String(cString: $0) } ?? "?"
        var bridge: String?
        if let b = virNetworkGetBridgeName(net) { bridge = String(cString: b); free(b) }
        return VirtNetwork(name: name, bridge: bridge,
                           active: virNetworkIsActive(net) == 1,
                           persistent: virNetworkIsPersistent(net) == 1)
    }

    public func domainCapabilities() async throws -> DomainCaps {
        try await run { conn in
            guard let x = virConnectGetDomainCapabilities(conn, nil, nil, nil, nil, 0) else {
                return DomainCaps.fallback
            }
            let xml = String(cString: x); free(x)
            guard let doc = try? XMLDocument(xmlString: xml), let root = doc.rootElement() else {
                return DomainCaps.fallback
            }
            func text(_ n: String) -> String? { root.elements(forName: n).first?.stringValue }
            let firmwareEFI = root.elements(forName: "os").first?
                .elements(forName: "enum").first(where: { $0.attribute(forName: "name")?.stringValue == "firmware" })?
                .elements(forName: "value").contains { $0.stringValue == "efi" } ?? false
            return DomainCaps(
                domainType: text("domain") ?? "kvm",
                emulator: text("path") ?? DomainCaps.fallback.emulator,
                arch: text("arch") ?? "x86_64",
                machine: "q35",
                firmwareEFI: firmwareEFI)
        }
    }

    // MARK: - XML parsing helpers

    private static func formatFromVolumeXML(_ xml: String) -> String? {
        guard let doc = try? XMLDocument(xmlString: xml),
              let target = doc.rootElement()?.elements(forName: "target").first,
              let fmt = target.elements(forName: "format").first?.attribute(forName: "type")?.stringValue
        else { return nil }
        return fmt
    }

    private static func parseNodeDevice(name: String, xml: String, kind: NodeDeviceKind) -> NodeDevice? {
        guard let doc = try? XMLDocument(xmlString: xml),
              let root = doc.rootElement() else { return nil }
        let caps = root.elements(forName: "capability")
        let wantType = (kind == .usb) ? "usb_device" : "pci"
        guard let cap = caps.first(where: { $0.attribute(forName: "type")?.stringValue == wantType })
        else { return nil }

        func text(_ n: String) -> String? { cap.elements(forName: n).first?.stringValue }
        func int(_ n: String) -> Int? { text(n).flatMap(Int.init) }
        let product = cap.elements(forName: "product").first?.stringValue
        let vendor = cap.elements(forName: "vendor").first?.stringValue
        let vendorID = cap.elements(forName: "vendor").first?.attribute(forName: "id")?.stringValue
        let productID = cap.elements(forName: "product").first?.attribute(forName: "id")?.stringValue

        let label = [vendor, product].compactMap { $0 }.joined(separator: " ").isEmpty
            ? name : [vendor, product].compactMap { $0 }.joined(separator: " ")

        if kind == .usb {
            // Skip hubs / root devices with no usable product id.
            return NodeDevice(id: name, kind: .usb, label: label,
                              vendorID: vendorID, productID: productID,
                              usbBus: int("bus"), usbDevice: int("device"),
                              pciDomain: nil, pciBus: nil, pciSlot: nil, pciFunction: nil)
        } else {
            return NodeDevice(id: name, kind: .pci, label: label,
                              vendorID: vendorID, productID: productID,
                              usbBus: nil, usbDevice: nil,
                              pciDomain: int("domain"), pciBus: int("bus"),
                              pciSlot: int("slot"), pciFunction: int("function"))
        }
    }
}
