import Foundation

/// Where a field reads/writes within a device's XML element.
public enum FieldLocator: Sendable, Hashable {
    case attr(String)                          // attribute on the device element
    case childAttr(child: String, attr: String) // attribute on a (created) child element
    case boolChild(String)                     // presence of a <name/> child
    case elementText(child: String?)           // text of self (nil) or a child element
    case custom(String)                        // handled specially by the UI (e.g. source pickers)
}

public struct MenuOption: Sendable, Hashable {
    public let value: String
    public let label: String
    public init(_ value: String, _ label: String? = nil) {
        self.value = value
        self.label = label ?? (value.isEmpty ? "Hypervisor default" : value)
    }
}

/// How a field is presented.
public enum FieldControl: Sendable {
    case text(placeholder: String = "")
    case menu([MenuOption])
    case toggle
    case int(min: Int, max: Int)
    case autoPort                              // "auto" toggle backed by autoport=yes / port=-1
    case networkSource                         // custom: virtual-network / bridge picker
    case storageVolume(isISO: Bool)            // custom: volume / path / create-new picker
    case hostDevice                            // custom: read-only host device summary
    case readonly
}

public struct DeviceField: Identifiable, Sendable {
    public let id: String
    public let label: String
    public let locator: FieldLocator
    public let control: FieldControl

    public init(_ id: String, _ label: String, _ locator: FieldLocator, _ control: FieldControl) {
        self.id = id; self.label = label; self.locator = locator; self.control = control
    }
}

public enum DeviceSchema {
    public static func fields(for kind: DeviceKind) -> [DeviceField] {
        switch kind {
        case .disk:
            return [
                .init("device", "Device", .attr("device"),
                      .menu([.init("disk", "Disk"), .init("lun", "LUN")])),
                .init("source", "Source", .custom("diskSource"), .storageVolume(isISO: false)),
                .init("bus", "Bus", .childAttr(child: "target", attr: "bus"), .menu(diskBuses)),
                .init("format", "Format", .childAttr(child: "driver", attr: "type"),
                      .menu([.init("qcow2"), .init("raw")])),
                .init("cache", "Cache", .childAttr(child: "driver", attr: "cache"), .menu(cacheModes)),
                .init("discard", "Discard", .childAttr(child: "driver", attr: "discard"),
                      .menu([.init(""), .init("ignore"), .init("unmap")])),
                .init("readonly", "Read-only", .boolChild("readonly"), .toggle),
                .init("shareable", "Shareable", .boolChild("shareable"), .toggle),
                .init("serial", "Serial", .elementText(child: "serial"), .text(placeholder: "optional")),
            ]
        case .cdrom:
            return [
                .init("source", "ISO Image", .custom("diskSource"), .storageVolume(isISO: true)),
                .init("bus", "Bus", .childAttr(child: "target", attr: "bus"),
                      .menu([.init("sata"), .init("ide"), .init("scsi"), .init("usb")])),
            ]
        case .interface:
            return [
                .init("source", "Network Source", .custom("netSource"), .networkSource),
                .init("model", "Device Model", .childAttr(child: "model", attr: "type"), .menu(nicModels)),
                .init("mac", "MAC Address", .childAttr(child: "mac", attr: "address"),
                      .text(placeholder: "auto")),
                .init("link", "Link State", .childAttr(child: "link", attr: "state"),
                      .menu([.init("", "default"), .init("up"), .init("down")])),
            ]
        case .graphics:
            return [
                .init("type", "Type", .attr("type"),
                      .menu([.init("spice", "SPICE"), .init("vnc", "VNC")])),
                .init("listen", "Address", .attr("listen"),
                      .menu([.init("", "Hypervisor default"), .init("127.0.0.1", "Localhost only"),
                             .init("0.0.0.0", "All interfaces")])),
                .init("port", "Port", .attr("port"), .autoPort),
                .init("passwd", "Password", .attr("passwd"), .text(placeholder: "none")),
                .init("gl", "OpenGL", .childAttr(child: "gl", attr: "enable"),
                      .menu([.init("", "default"), .init("yes", "On"), .init("no", "Off")])),
            ]
        case .video:
            return [
                .init("model", "Model", .childAttr(child: "model", attr: "type"), .menu(videoModels)),
            ]
        case .sound:
            return [
                .init("model", "Model", .attr("model"),
                      .menu([.init("ich9", "HDA (ICH9)"), .init("ich6", "HDA (ICH6)"),
                             .init("ac97", "AC97"), .init("usb", "USB"), .init("hda", "HDA")])),
            ]
        case .controller:
            return [
                .init("type", "Type", .attr("type"), .readonly),
                .init("model", "Model", .attr("model"), .text(placeholder: "Hypervisor default")),
            ]
        case .input:
            return [
                .init("type", "Type", .attr("type"),
                      .menu([.init("mouse", "Mouse"), .init("tablet", "Tablet"),
                             .init("keyboard", "Keyboard")])),
                .init("bus", "Bus", .attr("bus"),
                      .menu([.init("usb", "USB"), .init("virtio", "VirtIO"), .init("ps2", "PS/2")])),
            ]
        case .channel, .serial, .console:
            return [
                .init("type", "Backend", .attr("type"), .menu(charTypes)),
                .init("targetName", "Target Name", .childAttr(child: "target", attr: "name"),
                      .menu(channelTargets)),
                .init("path", "Source Path", .childAttr(child: "source", attr: "path"),
                      .text(placeholder: "for file / unix backends")),
            ]
        case .hostdev:
            return [ .init("source", "Host Device", .custom("hostdev"), .hostDevice) ]
        case .redirdev:
            return [
                .init("type", "Type", .attr("type"), .menu([.init("spicevmc", "SPICE"), .init("tcp", "TCP")])),
                .init("bus", "Bus", .attr("bus"), .menu([.init("usb", "USB")])),
            ]
        case .tpm:
            return [
                .init("model", "Model", .attr("model"),
                      .menu([.init("tpm-tis", "TIS"), .init("tpm-crb", "CRB"), .init("tpm-spapr", "SPAPR")])),
                .init("type", "Backend", .childAttr(child: "backend", attr: "type"),
                      .menu([.init("emulator", "Emulated"), .init("passthrough", "Passthrough")])),
                .init("version", "Version", .childAttr(child: "backend", attr: "version"),
                      .menu([.init("", "default"), .init("2.0"), .init("1.2")])),
            ]
        case .rng:
            return [
                .init("model", "Model", .attr("model"), .menu([.init("virtio")])),
                .init("backend", "Backend Model", .childAttr(child: "backend", attr: "model"),
                      .menu([.init("random"), .init("builtin")])),
                .init("device", "Device", .elementText(child: "backend"),
                      .text(placeholder: "/dev/urandom")),
            ]
        case .watchdog:
            return [
                .init("model", "Model", .attr("model"),
                      .menu([.init("i6300esb"), .init("ib700"), .init("diag288")])),
                .init("action", "Action", .attr("action"),
                      .menu([.init("reset"), .init("poweroff"), .init("shutdown"),
                             .init("pause"), .init("dump"), .init("none")])),
            ]
        case .filesystem:
            return [
                .init("driver", "Driver", .childAttr(child: "driver", attr: "type"),
                      .menu([.init("virtiofs"), .init("virtio-9p", "virtio-9p")])),
                .init("source", "Source Path", .childAttr(child: "source", attr: "dir"),
                      .text(placeholder: "/host/path")),
                .init("target", "Target", .childAttr(child: "target", attr: "dir"),
                      .text(placeholder: "mount tag")),
                .init("readonly", "Read-only", .boolChild("readonly"), .toggle),
            ]
        case .smartcard:
            return [
                .init("mode", "Mode", .attr("mode"),
                      .menu([.init("passthrough"), .init("host")])),
            ]
        case .memballoon:
            return [
                .init("model", "Model", .attr("model"),
                      .menu([.init("virtio"), .init("none")])),
            ]
        case .other:
            return []
        }
    }

    // Option lists
    static let diskBuses = ["virtio", "sata", "scsi", "usb", "ide", "nvme"].map { MenuOption($0) }
    static let nicModels = ["virtio", "e1000", "e1000e", "rtl8139"].map { MenuOption($0) }
    static let videoModels = ["virtio", "qxl", "vga", "bochs", "ramfb", "none"].map { MenuOption($0) }
    static let cacheModes = [MenuOption(""), MenuOption("none"), MenuOption("writeback"),
                             MenuOption("writethrough"), MenuOption("directsync"), MenuOption("unsafe")]
    static let charTypes = [MenuOption("pty", "PTY"), MenuOption("unix", "UNIX socket"),
                            MenuOption("file", "File"), MenuOption("tcp", "TCP"),
                            MenuOption("spicevmc", "SPICE Agent"), MenuOption("spiceport", "SPICE Port")]
    static let channelTargets = [MenuOption("", "—"),
                                 MenuOption("com.redhat.spice.0", "SPICE"),
                                 MenuOption("org.qemu.guest_agent.0", "QEMU Guest Agent"),
                                 MenuOption("org.spice-space.webdav.0", "WebDAV")]
}
