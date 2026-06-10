import Foundation

/// User choices from the New VM wizard.
public struct NewVMSpec: Sendable {
    public enum Firmware: String, Sendable, CaseIterable, Identifiable {
        case uefi = "UEFI", bios = "BIOS"
        public var id: String { rawValue }
    }
    public enum Install: Sendable, Equatable {
        case iso(String)          // boot the installer ISO
        case importDisk           // boot an existing disk (diskPath)
        case none                 // no install media
    }
    public enum Graphics: String, Sendable, CaseIterable, Identifiable {
        case spice = "SPICE", vnc = "VNC"
        public var id: String { rawValue }
    }

    public var name: String
    public var os: GuestOS                // per-OS tuning profile (see GuestOS)
    public var firmware: Firmware
    public var memoryMiB: Int
    public var vcpus: Int
    public var install: Install
    public var diskPath: String?          // target/imported disk
    public var networkSource: String      // "network-name" or "bridge:br0"
    public var graphics: Graphics

    public init(name: String = "", os: GuestOS = .defaultOS(in: .linux),
                firmware: Firmware = .uefi,
                memoryMiB: Int = 2048, vcpus: Int = 2, install: Install = .none,
                diskPath: String? = nil, networkSource: String = "default",
                graphics: Graphics = .spice) {
        self.name = name; self.os = os
        self.firmware = os.requiresUEFI ? .uefi : firmware
        self.memoryMiB = memoryMiB; self.vcpus = vcpus; self.install = install
        self.diskPath = diskPath; self.networkSource = networkSource; self.graphics = graphics
    }

    var diskBus: String { os.diskBus }
    var nicModel: String { os.nicModel }
    var clockOffset: String { os.clockOffset }
    var isISO: Bool { if case .iso = install { return true }; return false }
}

/// Generates a complete libvirt domain XML for a new guest. libvirt fills in the
/// emulator-specific bits (PCIe controllers, addresses) on `defineXML`.
public enum DomainTemplate {
    public static func buildXML(_ spec: NewVMSpec, domainType: String,
                                emulator: String, arch: String) -> String {
        let uuid = UUID().uuidString.lowercased()
        let memKiB = spec.memoryMiB * 1024

        let osBlock = spec.firmware == .uefi
            ? "<os firmware='efi'>\n    <type arch='\(arch)' machine='q35'>hvm</type>\n  </os>"
            : "<os>\n    <type arch='\(arch)' machine='q35'>hvm</type>\n  </os>"

        var disks = ""
        let diskDev = spec.diskBus == "virtio" ? "vda" : "sda"
        if let path = spec.diskPath, !path.isEmpty {
            let order = spec.isISO ? 2 : 1
            disks += """
                <disk type='file' device='disk'>
                  <driver name='qemu' type='qcow2'/>
                  <source file='\(esc(path))'/>
                  <target dev='\(diskDev)' bus='\(spec.diskBus)'/>
                  <boot order='\(order)'/>
                </disk>

            """
        }
        if case .iso(let iso) = spec.install, !iso.isEmpty {
            let cdDev = spec.diskBus == "sata" ? "sdb" : "sda"
            disks += """
                <disk type='file' device='cdrom'>
                  <driver name='qemu' type='raw'/>
                  <source file='\(esc(iso))'/>
                  <target dev='\(cdDev)' bus='sata'/>
                  <readonly/>
                  <boot order='1'/>
                </disk>

            """
        }

        let net: String
        if spec.networkSource.hasPrefix("bridge:") {
            net = "<interface type='bridge'>\n  <source bridge='\(esc(String(spec.networkSource.dropFirst(7))))'/>\n  <model type='\(spec.nicModel)'/>\n</interface>"
        } else {
            net = "<interface type='network'>\n  <source network='\(esc(spec.networkSource))'/>\n  <model type='\(spec.nicModel)'/>\n</interface>"
        }

        // Linux guests get virtio-gpu (QXL has a freeze bug on modern Ubuntu
        // kernels); Windows gets QXL, which has mature guest drivers.
        let video = "<video><model type='\(spec.os.videoModel)' heads='1'/></video>"
        let gfx = spec.graphics == .spice
            ? "<graphics type='spice' autoport='yes' listen='127.0.0.1'/>"
            : "<graphics type='vnc' port='-1' autoport='yes' listen='127.0.0.1'/>"

        // Windows runs noticeably better with Hyper-V enlightenments and the
        // hypervclock timer — same tuning virt-manager applies from osinfo-db.
        let hypervFeatures = spec.os.hyperv ? """

            <hyperv mode='custom'>
              <relaxed state='on'/>
              <vapic state='on'/>
              <spinlocks state='on' retries='8191'/>
            </hyperv>
        """ : ""
        let hypervTimer = spec.os.hyperv ? "\n    <timer name='hypervclock' present='yes'/>" : ""
        // Windows 11 refuses to install without a TPM 2.0 (host needs swtpm).
        let tpm = spec.os.requiresTPM ? """

            <tpm model='tpm-crb'>
              <backend type='emulator' version='2.0'/>
            </tpm>
        """ : ""

        return """
        <domain type='\(domainType)'>
          <name>\(esc(spec.name))</name>
          <uuid>\(uuid)</uuid>
          <memory unit='KiB'>\(memKiB)</memory>
          <currentMemory unit='KiB'>\(memKiB)</currentMemory>
          <vcpu>\(spec.vcpus)</vcpu>
          \(osBlock)
          <features><acpi/><apic/>\(hypervFeatures)</features>
          <cpu mode='host-passthrough'/>
          <clock offset='\(spec.clockOffset)'>
            <timer name='rtc' tickpolicy='catchup'/>
            <timer name='pit' tickpolicy='delay'/>
            <timer name='hpet' present='no'/>\(hypervTimer)
          </clock>
          <pm>
            <suspend-to-mem enabled='no'/>
            <suspend-to-disk enabled='no'/>
          </pm>
          <on_poweroff>destroy</on_poweroff>
          <on_reboot>restart</on_reboot>
          <on_crash>destroy</on_crash>
          <devices>
            <emulator>\(esc(emulator))</emulator>
            \(disks)\(net)
            <controller type='usb' model='qemu-xhci'/>
            <channel type='spicevmc'>
              <target type='virtio' name='com.redhat.spice.0'/>
            </channel>
            <channel type='unix'>
              <target type='virtio' name='org.qemu.guest_agent.0'/>
            </channel>
            <input type='tablet' bus='usb'/>\(tpm)
            \(gfx)
            \(video)
            <rng model='virtio'>
              <backend model='random'>/dev/urandom</backend>
            </rng>
            <memballoon model='virtio'/>
            <redirdev bus='usb' type='spicevmc'/>
          </devices>
        </domain>
        """
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
