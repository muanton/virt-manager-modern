import XCTest
@testable import DomainModel

final class DomainConfigTests: XCTestCase {
    let sample = """
    <domain type='qemu'>
      <name>web1</name>
      <uuid>11111111-2222-3333-4444-555555555555</uuid>
      <memory unit='KiB'>2097152</memory>
      <currentMemory unit='KiB'>1048576</currentMemory>
      <vcpu>2</vcpu>
      <os>
        <type arch='x86_64'>hvm</type>
        <boot dev='hd'/>
        <boot dev='network'/>
      </os>
      <devices>
        <disk type='file' device='disk'>
          <driver name='qemu' type='qcow2'/>
          <source file='/var/lib/libvirt/images/web1.qcow2'/>
          <target dev='vda' bus='virtio'/>
        </disk>
        <interface type='network'>
          <source network='default'/>
          <model type='virtio'/>
          <mac address='52:54:00:aa:bb:cc'/>
        </interface>
        <graphics type='vnc' port='5901' autoport='no' listen='127.0.0.1' passwd='secret'/>
      </devices>
    </domain>
    """

    func testParsing() throws {
        let c = try DomainConfig(xml: sample)
        XCTAssertEqual(c.name, "web1")
        XCTAssertEqual(c.vcpu, 2)
        XCTAssertEqual(c.memoryKiB, 2097152)
        XCTAssertEqual(c.currentMemoryKiB, 1048576)
        XCTAssertEqual(c.bootDevices, ["hd", "network"])
        XCTAssertEqual(c.disks.count, 1)
        XCTAssertEqual(c.disks.first?.target, "vda")
        XCTAssertEqual(c.disks.first?.bus, "virtio")
        XCTAssertEqual(c.interfaces.first?.mac, "52:54:00:aa:bb:cc")
        let g = try XCTUnwrap(c.graphics)
        XCTAssertEqual(g.kind, .vnc)
        XCTAssertEqual(g.port, 5901)
        XCTAssertEqual(g.listen, "127.0.0.1")
        XCTAssertEqual(g.password, "secret")
        XCTAssertTrue(g.listensOnLoopback)
    }

    func testRoundTripMutation() throws {
        var c = try DomainConfig(xml: sample)
        c.vcpu = 4
        c.currentMemoryKiB = 524288
        c.bootDevices = ["network", "hd"]
        let out = c.xmlString()

        // Re-parse the serialized output and confirm the edits stuck and the
        // rest of the document survived.
        let c2 = try DomainConfig(xml: out)
        XCTAssertEqual(c2.vcpu, 4)
        XCTAssertEqual(c2.currentMemoryKiB, 524288)
        XCTAssertEqual(c2.bootDevices, ["network", "hd"])
        XCTAssertEqual(c2.disks.count, 1)
        XCTAssertEqual(c2.graphics?.port, 5901)
    }

    func testVideoModelAndVirtioSwitch() throws {
        let qxl = """
        <domain type='qemu'>
          <name>vm</name>
          <devices>
            <video>
              <model type='qxl' ram='65536' vram='65536' vgamem='16384' heads='1' primary='yes'/>
            </video>
          </devices>
        </domain>
        """
        let c = try DomainConfig(xml: qxl)
        XCTAssertEqual(c.videoModel, "qxl")

        let newXML = try XCTUnwrap(c.xmlSwitchingVideoToVirtio())
        let c2 = try DomainConfig(xml: newXML)
        XCTAssertEqual(c2.videoModel, "virtio")
        // qxl-only attributes are dropped
        XCTAssertFalse(newXML.contains("vram="))
        XCTAssertFalse(newXML.contains("vgamem="))
        // non-qxl attributes kept
        XCTAssertTrue(newXML.contains("primary='yes'") || newXML.contains("primary=\"yes\""))
    }

    func testDeviceListAddRemove() throws {
        let c = try DomainConfig(xml: sample)
        var list = c.deviceList()
        XCTAssertTrue(list.contains { $0.id == "disk-0" && $0.kind == .disk })
        XCTAssertTrue(list.contains { $0.id == "interface-0" && $0.kind == .interface })
        XCTAssertTrue(list.contains { $0.kind == .graphics })

        try c.appendDeviceXML(DeviceBuilder.interface(
            sourceKind: "network", source: "default", model: "e1000", mac: nil))
        XCTAssertEqual(c.deviceList().filter { $0.kind == .interface }.count, 2)

        try c.appendDeviceXML(DeviceBuilder.usbRedir())
        XCTAssertTrue(c.deviceList().contains { $0.kind == .redirdev })

        c.removeDevice(id: "disk-0")
        XCTAssertEqual(c.deviceList().filter { $0.kind == .disk }.count, 0)

        // serialized output re-parses with the mutations intact
        let c2 = try DomainConfig(xml: c.xmlString())
        XCTAssertEqual(c2.deviceList().filter { $0.kind == .interface }.count, 2)
        XCTAssertTrue(c2.deviceList().contains { $0.kind == .redirdev })
    }

    func testSetDeviceXMLUpdatesDiskBus() throws {
        let c = try DomainConfig(xml: sample)
        var disk = try XCTUnwrap(c.disk(id: "disk-0"))
        XCTAssertEqual(disk.bus, "virtio")
        disk.bus = "sata"
        disk.target = "sda"
        try c.setDeviceXML(id: "disk-0", DeviceBuilder.disk(from: disk))
        let updated = try XCTUnwrap(c.disk(id: "disk-0"))
        XCTAssertEqual(updated.bus, "sata")
        XCTAssertEqual(updated.target, "sda")
    }

    func testSchemaFieldRoundTrips() throws {
        let c = try DomainConfig(xml: sample)

        // childAttr on the disk driver
        c.setField(deviceID: "disk-0", .childAttr(child: "driver", attr: "cache"), string: "writeback")
        XCTAssertEqual(c.fieldString(deviceID: "disk-0", .childAttr(child: "driver", attr: "cache")), "writeback")

        // boolChild toggle
        XCTAssertFalse(c.fieldBool(deviceID: "disk-0", .boolChild("readonly")))
        c.setField(deviceID: "disk-0", .boolChild("readonly"), bool: true)
        XCTAssertTrue(c.fieldBool(deviceID: "disk-0", .boolChild("readonly")))
        c.setField(deviceID: "disk-0", .boolChild("readonly"), bool: false)
        XCTAssertFalse(c.fieldBool(deviceID: "disk-0", .boolChild("readonly")))

        // attr on graphics
        c.setField(deviceID: "graphics-0", .attr("passwd"), string: "secret")
        XCTAssertEqual(c.fieldString(deviceID: "graphics-0", .attr("passwd")), "secret")

        // composite interface source
        c.setInterfaceSource(deviceID: "interface-0", type: "bridge", source: "br0")
        XCTAssertEqual(c.fieldString(deviceID: "interface-0", .attr("type")), "bridge")
        XCTAssertEqual(c.nic(id: "interface-0")?.source, "br0")

        // serializes + reparses cleanly
        _ = try DomainConfig(xml: c.xmlString())
    }

    func testDefaultDeviceXMLAppends() throws {
        let c = try DomainConfig(xml: sample)
        for kind in [DeviceKind.sound, .input, .watchdog, .rng, .tpm, .channel, .redirdev] {
            let xml = try XCTUnwrap(DeviceBuilder.defaultXML(for: kind))
            try c.appendDeviceXML(xml)
        }
        let c2 = try DomainConfig(xml: c.xmlString())
        XCTAssertTrue(c2.deviceList().contains { $0.kind == .watchdog })
        XCTAssertTrue(c2.deviceList().contains { $0.kind == .tpm })
    }

    func testNewVMTemplateLinuxISO() throws {
        var spec = NewVMSpec(name: "test-vm", os: .defaultOS(in: .linux), firmware: .uefi,
                             memoryMiB: 2048, vcpus: 2, install: .iso("/iso/ubuntu.iso"),
                             diskPath: "/images/test.qcow2", networkSource: "host-bridge",
                             graphics: .spice)
        let xml = DomainTemplate.buildXML(spec, domainType: "kvm",
                                          emulator: "/usr/bin/qemu-system-x86_64", arch: "x86_64")
        let c = try DomainConfig(xml: xml)        // must be valid domain XML
        XCTAssertEqual(c.name, "test-vm")
        XCTAssertTrue(xml.contains("<domain type='kvm'>"))
        XCTAssertTrue(xml.contains("firmware='efi'"))
        // disk virtio + cdrom present, cdrom boots first
        let disks = c.deviceList().filter { $0.kind == .disk || $0.kind == .cdrom }
        XCTAssertEqual(disks.count, 2)
        XCTAssertTrue(c.deviceList().contains { $0.kind == .cdrom })
        XCTAssertTrue(xml.contains("bus='virtio'"))
        XCTAssertTrue(c.graphics?.kind == .spice)
        spec.memoryMiB = 4096
        XCTAssertTrue(DomainTemplate.buildXML(spec, domainType: "kvm",
            emulator: "x", arch: "x86_64").contains("\(4096 * 1024)"))
    }

    func testNewVMTemplateWindowsBIOSImport() throws {
        // Windows 10 — unlike Windows 11 it does not force UEFI, so BIOS sticks.
        let win10 = GuestOS.catalog.first { $0.id == "win10" }!
        let spec = NewVMSpec(name: "win", os: win10, firmware: .bios,
                             memoryMiB: 4096, vcpus: 4, install: .importDisk,
                             diskPath: "/images/win.qcow2", networkSource: "default",
                             graphics: .vnc)
        let xml = DomainTemplate.buildXML(spec, domainType: "kvm",
                                          emulator: "/usr/bin/qemu-system-x86_64", arch: "x86_64")
        let c = try DomainConfig(xml: xml)
        XCTAssertFalse(xml.contains("firmware='efi'"))       // BIOS
        XCTAssertTrue(xml.contains("bus='sata'"))            // Windows → sata
        XCTAssertTrue(xml.contains("offset='localtime'"))
        XCTAssertFalse(c.deviceList().contains { $0.kind == .cdrom })  // import → no CDROM
        XCTAssertEqual(c.graphics?.kind, .vnc)
    }

    func testHiddenControllersFilteredButPreserved() throws {
        let xml = """
        <domain type='kvm'><name>q35</name><devices>
          <controller type='pci' index='0' model='pcie-root'/>
          <controller type='pci' index='1' model='pcie-root-port'/>
          <controller type='pci' index='2' model='pcie-root-port'/>
          <controller type='pci' index='3' model='pcie-root-port'/>
          <controller type='usb' index='0' model='qemu-xhci'/>
          <controller type='sata' index='0'/>
          <interface type='network'><source network='default'/><model type='virtio'/></interface>
        </devices></domain>
        """
        let c = try DomainConfig(xml: xml)
        let controllers = c.deviceList().filter { $0.kind == .controller }
        // pcie-root + usb + sata shown; the 3 root ports hidden
        XCTAssertEqual(controllers.count, 3)
        XCTAssertTrue(controllers.contains { $0.title == "Controller PCIe 0" })
        XCTAssertTrue(controllers.contains { $0.title == "Controller USB 0" })
        XCTAssertTrue(controllers.contains { $0.title == "Controller SATA 0" })

        // NIC sorts before any controller (type-rank order).
        let kinds = c.deviceList().map(\.kind)
        XCTAssertLessThan(kinds.firstIndex(of: .interface)!, kinds.firstIndex(of: .controller)!)

        // A visible controller's positional id still resolves to the right element.
        let usb = try XCTUnwrap(controllers.first { $0.title.contains("USB") })
        XCTAssertEqual(usb.id, "controller-4")   // 5th controller in document order
        XCTAssertTrue(c.deviceXML(id: usb.id)?.contains("qemu-xhci") == true)

        // The hidden root ports remain in the serialized XML.
        let out = c.xmlString()
        XCTAssertEqual(out.components(separatedBy: "pcie-root-port").count - 1, 3)
        // The NIC after the controllers is still listed.
        XCTAssertTrue(c.deviceList().contains { $0.kind == .interface })
    }

    func testGeneralCPUBootAccessors() throws {
        var c = try DomainConfig(xml: sample)
        c.title = "My Server"
        c.desc = "web frontend"
        c.cpuMode = "host-passthrough"
        c.cpuModelName = "Skylake"
        c.cpuTopology = (sockets: 2, cores: 4, threads: 2)
        c.bootMenu = true

        let c2 = try DomainConfig(xml: c.xmlString())
        XCTAssertEqual(c2.title, "My Server")
        XCTAssertEqual(c2.desc, "web frontend")
        XCTAssertEqual(c2.cpuMode, "host-passthrough")
        XCTAssertEqual(c2.cpuModelName, "Skylake")
        XCTAssertEqual(c2.cpuTopology?.cores, 4)
        XCTAssertTrue(c2.bootMenu)

        // clear topology + boot menu
        c.cpuTopology = nil
        c.bootMenu = false
        let c3 = try DomainConfig(xml: c.xmlString())
        XCTAssertNil(c3.cpuTopology)
        XCTAssertFalse(c3.bootMenu)
    }

    func testReadOnlyHypervisorFields() throws {
        let spec = NewVMSpec(name: "vm", os: .defaultOS(in: .linux), firmware: .uefi,
                             memoryMiB: 2048, vcpus: 2, install: .none,
                             diskPath: "/d.qcow2", networkSource: "default", graphics: .spice)
        let xml = DomainTemplate.buildXML(spec, domainType: "kvm",
                                          emulator: "/usr/bin/qemu-system-x86_64", arch: "x86_64")
        let c = try DomainConfig(xml: xml)
        XCTAssertEqual(c.domainType, "kvm")
        XCTAssertEqual(c.arch, "x86_64")
        XCTAssertEqual(c.machine, "q35")
        XCTAssertEqual(c.emulator, "/usr/bin/qemu-system-x86_64")
        XCTAssertEqual(c.firmwareLabel, "UEFI")
    }

    func testNextTargetDev() throws {
        let c = try DomainConfig(xml: sample)   // already has vda
        XCTAssertEqual(c.nextTargetDev(bus: "virtio"), "vdb")
        XCTAssertEqual(c.nextTargetDev(bus: "sata"), "sda")
    }

    func testMemoryUnitConversion() throws {
        let xml = sample.replacingOccurrences(
            of: "<memory unit='KiB'>2097152</memory>",
            with: "<memory unit='MiB'>2048</memory>")
        let c = try DomainConfig(xml: xml)
        XCTAssertEqual(c.memoryKiB, 2_097_152)
    }
}

extension DomainConfigTests {
    /// The New VM wizard writes per-device <boot order='N'/>; the Boot panel
    /// writes os-level <boot dev='…'/>. libvirt rejects XML containing both,
    /// so the setter must strip the per-device form, and the getter must
    /// surface the per-device order when no os-level entries exist.
    func testBootDevicesBridgesPerDeviceBootOrder() throws {
        let wizardStyle = """
        <domain type='kvm'>
          <name>nv</name><uuid>11111111-2222-3333-4444-555555555556</uuid>
          <memory unit='KiB'>1048576</memory><vcpu>2</vcpu>
          <os><type arch='aarch64'>hvm</type></os>
          <devices>
            <disk type='file' device='disk'>
              <source file='/i/nv.qcow2'/><target dev='vda' bus='virtio'/>
              <boot order='2'/>
            </disk>
            <disk type='file' device='cdrom'>
              <source file='/i/nv.iso'/><target dev='sda' bus='sata'/>
              <boot order='1'/>
            </disk>
          </devices>
        </domain>
        """
        var cfg = try DomainConfig(xml: wizardStyle)
        XCTAssertEqual(cfg.bootDevices, ["cdrom", "hd"])

        cfg.bootDevices = ["hd", "cdrom"]
        let out = cfg.xmlString()
        XCTAssertFalse(out.contains("boot order"), "per-device boot must be stripped")
        XCTAssertTrue(out.contains("<boot dev=\"hd\""))
        XCTAssertEqual(cfg.bootDevices, ["hd", "cdrom"])
    }
}

extension DomainConfigTests {
    private var rulesXML: String { """
        <domain type='kvm'>
          <name>r</name><uuid>11111111-2222-3333-4444-555555555557</uuid>
          <memory unit='KiB'>1048576</memory><vcpu>2</vcpu>
          <os><type arch='aarch64'>hvm</type><boot dev='hd'/></os>
          <devices>
            <disk type='file' device='disk'>
              <source file='/i/a.qcow2'/><target dev='vda' bus='virtio'/>
            </disk>
            <disk type='file' device='cdrom'>
              <source file='/i/a.iso'/><target dev='sda' bus='sata'/>
            </disk>
            <controller type='sata' index='0'/>
            <controller type='usb' model='qemu-xhci'/>
            <interface type='network'><source network='default'/></interface>
            <graphics type='spice' autoport='yes'/>
            <video><model type='virtio'/></video>
            <input type='tablet' bus='usb'/>
            <sound model='ich9'/>
            <channel type='spicevmc'><target type='virtio' name='com.redhat.spice.0'/></channel>
            <memballoon model='virtio'/>
          </devices>
        </domain>
        """
    }

    func testRemovabilityRules() throws {
        let cfg = try DomainConfig(xml: rulesXML)
        let devices = cfg.deviceList()
        func dev(_ id: String) -> Device { devices.first { $0.id == id }! }

        // SATA controller has the CDROM attached → blocked.
        XCTAssertTrue(dev("controller-0").removability.isBlocked)
        // USB controller has the tablet attached → blocked.
        XCTAssertTrue(dev("controller-1").removability.isBlocked)
        // Only data disk → boot warning, still removable.
        if case .warning = dev("disk-0").removability {} else {
            XCTFail("boot disk should warn, got \(dev("disk-0").removability)")
        }
        XCTAssertTrue(dev("disk-0").removable)
        // Only graphics → warning. Only NIC → warning. Sound → ok.
        if case .warning = dev("graphics-0").removability {} else { XCTFail("graphics") }
        if case .warning = dev("interface-0").removability {} else { XCTFail("nic") }
        XCTAssertEqual(dev("sound-0").removability, .ok)
    }

    func testAddRules() throws {
        let cfg = try DomainConfig(xml: rulesXML)
        // memballoon present (hidden from the list but in the XML) → blocked.
        XCTAssertNotNil(cfg.addBlockReason(for: .memballoon))
        // No TPM/watchdog yet → allowed.
        XCTAssertNil(cfg.addBlockReason(for: .tpm))
        XCTAssertNil(cfg.addBlockReason(for: .watchdog))
        // SPICE present → spicevmc devices allowed; duplicates detectable.
        XCTAssertNil(cfg.addBlockReason(for: .redirdev))
        XCTAssertTrue(cfg.graphicsTypes.contains("spice"))
        XCTAssertTrue(cfg.channelTargetNames.contains("com.redhat.spice.0"))
        XCTAssertTrue(cfg.inputPairs.contains("tablet/usb"))

        // Without SPICE graphics, spicevmc devices are gated.
        let noSpice = rulesXML.replacingOccurrences(
            of: "<graphics type='spice' autoport='yes'/>",
            with: "<graphics type='vnc' autoport='yes'/>")
        let cfg2 = try DomainConfig(xml: noSpice)
        XCTAssertNotNil(cfg2.addBlockReason(for: .redirdev))
        XCTAssertNotNil(cfg2.addBlockReason(for: .smartcard))
    }
}

extension DomainConfigTests {
    func testCloneXMLTransform() throws {
        let xml = """
        <domain type='kvm'>
          <name>orig</name><uuid>aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee</uuid>
          <memory unit='KiB'>1048576</memory><vcpu>2</vcpu>
          <os><type arch='aarch64'>hvm</type>
            <nvram>/var/lib/libvirt/qemu/nvram/orig_VARS.fd</nvram>
          </os>
          <devices>
            <disk type='file' device='disk'>
              <source file='/i/orig.qcow2'/><target dev='vda' bus='virtio'/>
            </disk>
            <disk type='file' device='cdrom'>
              <source file='/i/installer.iso'/><target dev='sda' bus='sata'/>
            </disk>
            <interface type='network'>
              <source network='default'/><mac address='52:54:00:11:22:33'/>
            </interface>
          </devices>
        </domain>
        """
        let cfg = try DomainConfig(xml: xml)
        let out = cfg.xmlForClone(newName: "copy",
                                  diskPathMap: ["/i/orig.qcow2": "/i/copy.qcow2",
                                                "/i/installer.iso": ""])  // skip ISO
        XCTAssertTrue(out.contains("<name>copy</name>"))
        XCTAssertFalse(out.contains("aaaaaaaa-bbbb"), "fresh UUID expected")
        XCTAssertFalse(out.contains("52:54:00:11:22:33"), "MACs must be stripped")
        XCTAssertFalse(out.contains("nvram"), "per-VM NVRAM must be dropped")
        XCTAssertTrue(out.contains("/i/copy.qcow2"))
        XCTAssertFalse(out.contains("/i/installer.iso"), "skipped disk keeps no source")
        // The original document is untouched.
        XCTAssertTrue(cfg.xmlString().contains("<name>orig</name>"))
    }

    func testDomainConfigDiffDetectsDeviceAndMemoryChanges() throws {
        let saved = """
        <domain type='kvm'>
          <name>vm</name><memory unit='KiB'>2097152</memory><vcpu>2</vcpu>
          <os><type arch='x86_64'>hvm</type><boot dev='hd'/></os>
          <devices>
            <disk type='file' device='disk'>
              <source file='/v/a.qcow2'/><target dev='vda' bus='virtio'/>
            </disk>
          </devices>
        </domain>
        """
        let live = """
        <domain type='kvm'>
          <name>vm</name><memory unit='KiB'>4194304</memory><vcpu>4</vcpu>
          <currentMemory unit='KiB'>4194304</currentMemory>
          <os><type arch='x86_64'>hvm</type><boot dev='hd'/></os>
          <devices>
            <disk type='file' device='disk'>
              <source file='/v/a.qcow2'/><target dev='vda' bus='virtio'/>
            </disk>
            <interface type='network'>
              <source network='default'/><model type='virtio'/>
            </interface>
          </devices>
        </domain>
        """
        let changes = try DomainConfigDiff.changes(liveXML: live, savedXML: saved)
        XCTAssertTrue(changes.contains { $0.label == "vCPUs" })
        XCTAssertTrue(changes.contains { $0.label == "Maximum memory" })
        XCTAssertTrue(changes.contains { $0.label == "Device" && $0.liveValue.contains("NIC") })
    }

    func testGuestOSCatalogIncludesCurrentReleases() {
        let ids = Set(GuestOS.catalog.map(\.id))
        XCTAssertTrue(ids.contains("ubuntu26.04"))
        XCTAssertTrue(ids.contains("fedora44"))
        XCTAssertTrue(ids.contains("rhel10"))
        XCTAssertTrue(ids.contains("opensuse16"))
        XCTAssertTrue(ids.contains("freebsd151"))
        XCTAssertFalse(ids.contains("fedora42"), "retired profiles should be removed")
    }
}
