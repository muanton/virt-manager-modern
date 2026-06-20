import Foundation

/// A category of libvirt `<devices>` child, used for the hardware list's icon,
/// label, and which editor to show.
public enum DeviceKind: Equatable, Sendable {
    case disk, cdrom, interface, graphics, video, controller, sound, input
    case channel, serial, console, hostdev, tpm, rng, memballoon
    case watchdog, filesystem, smartcard
    case other(String)   // the raw element name

    public var label: String {
        switch self {
        case .disk: return "Disk"
        case .cdrom: return "CD-ROM"
        case .interface: return "Network"
        case .graphics: return "Display"
        case .video: return "Video"
        case .controller: return "Controller"
        case .sound: return "Sound"
        case .input: return "Input"
        case .channel: return "Channel"
        case .serial: return "Serial"
        case .console: return "Console"
        case .hostdev: return "Host Device"
        case .tpm: return "TPM"
        case .rng: return "RNG"
        case .memballoon: return "Memory Balloon"
        case .watchdog: return "Watchdog"
        case .filesystem: return "Filesystem"
        case .smartcard: return "Smartcard"
        case .other(let n): return n.capitalized
        }
    }

    public var symbol: String {
        switch self {
        case .disk: return "internaldrive"
        case .cdrom: return "opticaldiscdrive"
        case .interface: return "network"
        case .graphics: return "display"
        case .video: return "rectangle.on.rectangle"
        case .controller: return "cable.connector"
        case .sound: return "speaker.wave.2"
        case .input: return "keyboard"
        case .channel: return "antenna.radiowaves.left.and.right"
        case .serial, .console: return "terminal"
        case .hostdev: return "cpu"
        case .tpm: return "lock.shield"
        case .rng: return "dice"
        case .memballoon: return "memorychip"
        case .watchdog: return "timer"
        case .filesystem: return "folder"
        case .smartcard: return "creditcard"
        case .other: return "puzzlepiece"
        }
    }

    /// The libvirt `<devices>` element name this kind serializes to.
    var elementName: String {
        switch self {
        case .disk, .cdrom: return "disk"
        case .interface: return "interface"
        case .graphics: return "graphics"
        case .video: return "video"
        case .controller: return "controller"
        case .sound: return "sound"
        case .input: return "input"
        case .channel: return "channel"
        case .serial: return "serial"
        case .console: return "console"
        case .hostdev: return "hostdev"
        case .tpm: return "tpm"
        case .rng: return "rng"
        case .memballoon: return "memballoon"
        case .watchdog: return "watchdog"
        case .filesystem: return "filesystem"
        case .smartcard: return "smartcard"
        case .other(let n): return n
        }
    }
}

/// Whether (and how safely) a device can be removed from the VM.
public enum Removability: Equatable, Sendable {
    case ok
    /// Allowed, but the confirmation should spell out the consequence.
    case warning(String)
    /// Not allowed — removal would break the machine; reason shown in the UI.
    case blocked(String)

    public var isBlocked: Bool { if case .blocked = self { return true }; return false }
    public var reason: String? {
        switch self {
        case .ok: return nil
        case .warning(let r), .blocked(let r): return r
        }
    }
}

/// A row in the hardware list. `id` is positional within one loaded document
/// (`"<elementName>-<indexAmongSameName>"`, e.g. `disk-0`, `interface-1`).
public struct Device: Identifiable, Sendable {
    public let id: String
    public let kind: DeviceKind
    public let title: String
    public let subtitle: String
    public let removability: Removability

    public var removable: Bool { !removability.isBlocked }
}

/// Builds well-formed `<device>` XML fragments for Add Hardware and the typed
/// editors. Pure functions — also covered by unit tests.
public enum DeviceBuilder {
    public static func disk(path: String, format: String, bus: String,
                            target: String, readOnly: Bool) -> String {
        var s = "<disk type='file' device='disk'>\n"
        s += "  <driver name='qemu' type='\(esc(format))'/>\n"
        s += "  <source file='\(esc(path))'/>\n"
        s += "  <target dev='\(esc(target))' bus='\(esc(bus))'/>\n"
        if readOnly { s += "  <readonly/>\n" }
        s += "</disk>"
        return s
    }

    public static func cdrom(path: String, bus: String, target: String) -> String {
        var s = "<disk type='file' device='cdrom'>\n"
        s += "  <driver name='qemu' type='raw'/>\n"
        if !path.isEmpty { s += "  <source file='\(esc(path))'/>\n" }
        s += "  <target dev='\(esc(target))' bus='\(esc(bus))'/>\n"
        s += "  <readonly/>\n"
        s += "</disk>"
        return s
    }

    public static func interface(sourceKind: String, source: String,
                                 model: String, mac: String?) -> String {
        var s = "<interface type='\(esc(sourceKind))'>\n"
        let attr = sourceKind == "bridge" ? "bridge" : "network"
        s += "  <source \(attr)='\(esc(source))'/>\n"
        s += "  <model type='\(esc(model))'/>\n"
        if let mac, !mac.isEmpty { s += "  <mac address='\(esc(mac))'/>\n" }
        s += "</interface>"
        return s
    }

    /// SPICE agent channel (clipboard, resolution, etc.).
    public static func spiceChannel() -> String {
        "<channel type='spicevmc'>\n  <target type='virtio' name='com.redhat.spice.0'/>\n</channel>"
    }

    /// QEMU guest agent channel.
    public static func guestAgentChannel() -> String {
        "<channel type='unix'>\n  <target type='virtio' name='org.qemu.guest_agent.0'/>\n</channel>"
    }

    public static func disk(from d: DiskInfo) -> String {
        if d.device == "cdrom" {
            return cdrom(path: d.source ?? "", bus: d.bus ?? "sata", target: d.target)
        }
        return disk(path: d.source ?? "", format: d.driverType ?? "qcow2",
                    bus: d.bus ?? "virtio", target: d.target, readOnly: false)
    }

    public static func interface(from n: NICInfo) -> String {
        interface(sourceKind: n.type == "bridge" ? "bridge" : "network",
                  source: n.source ?? "default", model: n.model ?? "virtio", mac: n.mac)
    }

    /// A minimal valid element for adding a new device of `kind`. Returns nil for
    /// kinds the Add flow builds specially (disk/cdrom need a target; hostdev needs
    /// a host device).
    public static func defaultXML(for kind: DeviceKind) -> String? {
        switch kind {
        case .interface:  return interface(sourceKind: "network", source: "default", model: "virtio", mac: nil)
        case .graphics:   return "<graphics type='vnc' port='-1' autoport='yes' listen='127.0.0.1'/>"
        case .video:      return "<video><model type='virtio' heads='1'/></video>"
        case .sound:      return "<sound model='ich9'/>"
        case .input:      return "<input type='tablet' bus='usb'/>"
        case .controller: return "<controller type='usb' model='qemu-xhci'/>"
        case .channel:    return spiceChannel()
        case .serial:     return "<serial type='pty'/>"
        case .console:    return "<console type='pty'/>"
        case .watchdog:   return "<watchdog model='i6300esb' action='reset'/>"
        case .rng:        return "<rng model='virtio'>\n  <backend model='random'>/dev/urandom</backend>\n</rng>"
        case .tpm:        return "<tpm model='tpm-tis'>\n  <backend type='emulator' version='2.0'/>\n</tpm>"
        case .memballoon: return "<memballoon model='virtio'/>"
        case .smartcard:  return "<smartcard mode='passthrough' type='spicevmc'/>"
        case .filesystem: return "<filesystem type='mount'>\n  <driver type='virtiofs'/>\n  <source dir='/'/>\n  <target dir='mount0'/>\n</filesystem>"
        case .disk, .cdrom, .hostdev, .other: return nil
        }
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
