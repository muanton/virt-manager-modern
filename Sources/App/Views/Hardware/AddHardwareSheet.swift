import SwiftUI
import DomainModel
import LibvirtKit

struct AddHardwareSheet: View {
    @ObservedObject var model: HardwareModel
    @Environment(\.dismiss) private var dismiss

    enum Category: String, CaseIterable, Identifiable {
        case disk = "Storage", cdrom = "CD-ROM", network = "Network"
        case controller = "Controller", input = "Input"
        case graphics = "Graphics", video = "Video", sound = "Sound"
        case serial = "Serial", console = "Console", channel = "Channel"
        case usbredir = "USB Redirection", usbhost = "USB Host Device", pcihost = "PCI Host Device"
        case watchdog = "Watchdog", rng = "RNG", tpm = "TPM"
        case filesystem = "Filesystem", smartcard = "Smartcard", memballoon = "Memory Balloon"
        var id: String { rawValue }
    }
    @State private var category: Category = .disk
    @State private var working = false
    @State private var error: String?

    // Storage
    @State private var storageMode = "existing"   // existing | path | new
    @State private var volumePath = ""
    @State private var customPath = ""
    @State private var diskBus = "virtio"
    @State private var cdromBus = "sata"
    @State private var diskFormat = "qcow2"
    @State private var newName = ""
    @State private var newPool = "default"
    @State private var newSize: Double = 20
    // Network / device choices
    @State private var netSel = ""
    @State private var netModel = "virtio"
    @State private var bridge = ""
    @State private var inputType = "tablet"
    @State private var inputBus = "usb"
    @State private var gfxType = "vnc"
    @State private var videoModel = "virtio"
    @State private var soundModel = "ich9"
    @State private var ctrlType = "usb"
    @State private var ctrlModel = "qemu-xhci"
    @State private var channelTarget = "com.redhat.spice.0"
    @State private var wdModel = "i6300esb"
    @State private var wdAction = "reset"
    @State private var tpmModel = "tpm-tis"
    @State private var tpmVersion = "2.0"
    @State private var fsSource = ""
    @State private var fsTarget = "mount0"
    @State private var usbSel = ""
    @State private var pciSel = ""

    var body: some View {
        NavigationSplitView {
            List(Category.allCases, selection: Binding(
                get: { category }, set: { if let v = $0 { category = v } })) { cat in
                if let reason = staticBlockReason(cat) {
                    Text(cat.rawValue).foregroundStyle(.tertiary).tag(cat).help(reason)
                } else {
                    Text(cat.rawValue).tag(cat)
                }
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            VStack(spacing: 0) {
                Form {
                    if let reason = blockReason {
                        Section {
                            Label(reason, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                    form
                }.formStyle(.grouped)
                if let error { Text(error).foregroundStyle(.red).font(.caption).padding(.horizontal) }
                Divider()
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(working ? "Adding…" : "Add") { add() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(working || !isValid || blockReason != nil)
                }
                .padding()
            }
        }
        .frame(width: 640, height: 460)
        .task { await model.loadHostResources() }
    }

    // MARK: - Add rules

    /// Selection-independent reason a category can't be added (grays the row).
    private func staticBlockReason(_ c: Category) -> String? {
        switch c {
        case .memballoon: return model.addBlockReason(for: .memballoon)
        case .tpm:        return model.addBlockReason(for: .tpm)
        case .watchdog:   return model.addBlockReason(for: .watchdog)
        case .usbredir:   return model.addBlockReason(for: .redirdev)
        case .smartcard:  return model.addBlockReason(for: .smartcard)
        default:          return nil
        }
    }

    /// Why the current selection can't be added (nil = allowed). Includes
    /// option-dependent duplicates on top of the static category rules.
    private var blockReason: String? {
        if let r = staticBlockReason(category) { return r }
        switch category {
        case .graphics where model.graphicsTypes.contains(gfxType):
            return "A \(gfxType.uppercased()) display already exists — only one per protocol is allowed."
        case .channel where model.channelTargetNames.contains(channelTarget):
            return "A channel with target \(channelTarget) already exists."
        case .input where model.inputPairs.contains("\(inputType)/\(inputBus)"):
            return "A \(inputType) on \(inputBus) already exists."
        default:
            return nil
        }
    }

    @ViewBuilder private var form: some View {
        switch category {
        case .disk:
            Picker("Source", selection: $storageMode) {
                Text("Existing volume").tag("existing")
                Text("Create new volume").tag("new")
                Text("File path").tag("path")
            }
            switch storageMode {
            case "existing":
                Picker("Volume", selection: $volumePath) {
                    Text("Select…").tag("")
                    ForEach(diskVolumes) { Text("\($0.name) (\($0.pool))").tag($0.path) }
                }
            case "new":
                LabeledContent("Name") { TextField("disk", text: $newName) }
                Picker("Pool", selection: $newPool) { ForEach(model.storagePools, id: \.self) { Text($0) } }
                Picker("Format", selection: $diskFormat) { Text("qcow2").tag("qcow2"); Text("raw").tag("raw") }
                LabeledContent("Size (GiB)") {
                    TextField("", value: $newSize, format: .number).frame(width: 80).multilineTextAlignment(.trailing)
                }
            default:
                LabeledContent("Path") { TextField("/var/lib/libvirt/images/disk.qcow2", text: $customPath) }
            }
            Picker("Bus", selection: $diskBus) { ForEach(["virtio","sata","scsi","usb","ide"], id: \.self) { Text($0) } }
        case .cdrom:
            Picker("ISO", selection: $volumePath) {
                Text("Empty drive").tag("")
                ForEach(isoVolumes) { Text("\($0.name) (\($0.pool))").tag($0.path) }
            }
            LabeledContent("Or path") { TextField("/path/to.iso", text: $customPath) }
            Picker("Bus", selection: $cdromBus) { ForEach(["sata","ide","scsi"], id: \.self) { Text($0) } }
        case .network:
            Picker("Source", selection: $netSel) {
                ForEach(model.networks) { Text("Virtual network: \($0.name)").tag("net:\($0.name)") }
                Text("Bridge device…").tag("bridge")
            }
            if netSel == "bridge" { LabeledContent("Bridge") { TextField("br0", text: $bridge) } }
            Picker("Model", selection: $netModel) { ForEach(["virtio","e1000","e1000e","rtl8139"], id: \.self) { Text($0) } }
        case .input:
            Picker("Type", selection: $inputType) { Text("Tablet").tag("tablet"); Text("Mouse").tag("mouse"); Text("Keyboard").tag("keyboard") }
            Picker("Bus", selection: $inputBus) { Text("USB").tag("usb"); Text("VirtIO").tag("virtio") }
        case .graphics:
            Picker("Type", selection: $gfxType) { Text("VNC").tag("vnc"); Text("SPICE").tag("spice") }
        case .video:
            Picker("Model", selection: $videoModel) { ForEach(["virtio","qxl","vga","bochs","ramfb","none"], id: \.self) { Text($0) } }
        case .sound:
            Picker("Model", selection: $soundModel) { ForEach(["ich9","ich6","ac97","usb"], id: \.self) { Text($0) } }
        case .controller:
            Picker("Type", selection: $ctrlType) { ForEach(["usb","scsi","virtio-serial","sata","pci"], id: \.self) { Text($0) } }
            LabeledContent("Model") { TextField("default", text: $ctrlModel) }
        case .serial, .console:
            Text("Adds a \(category.rawValue.lowercased()) (PTY).").foregroundStyle(.secondary)
        case .channel:
            Picker("Target", selection: $channelTarget) {
                Text("SPICE agent").tag("com.redhat.spice.0")
                Text("QEMU guest agent").tag("org.qemu.guest_agent.0")
                Text("WebDAV").tag("org.spice-space.webdav.0")
            }
        case .usbredir:
            Text("Adds a SPICE USB redirection channel.").foregroundStyle(.secondary)
        case .usbhost:
            hostDevicePicker(devices: model.usbDevices, selection: $usbSel)
        case .pcihost:
            hostDevicePicker(devices: model.pciDevices, selection: $pciSel)
        case .watchdog:
            Picker("Model", selection: $wdModel) { ForEach(["i6300esb","ib700","diag288"], id: \.self) { Text($0) } }
            Picker("Action", selection: $wdAction) { ForEach(["reset","poweroff","shutdown","pause","dump","none"], id: \.self) { Text($0) } }
        case .tpm:
            Picker("Model", selection: $tpmModel) { Text("TIS").tag("tpm-tis"); Text("CRB").tag("tpm-crb") }
            Picker("Version", selection: $tpmVersion) { Text("2.0").tag("2.0"); Text("1.2").tag("1.2") }
        case .filesystem:
            LabeledContent("Source (host)") { TextField("/host/path", text: $fsSource) }
            LabeledContent("Target tag") { TextField("mount0", text: $fsTarget) }
        case .rng, .smartcard, .memballoon:
            Text("Adds a \(category.rawValue.lowercased()) with default settings.").foregroundStyle(.secondary)
        }
    }

    private func hostDevicePicker(devices: [NodeDevice], selection: Binding<String>) -> some View {
        Group {
            if devices.isEmpty {
                Text("No host devices found.").foregroundStyle(.secondary)
            } else {
                Picker("Device", selection: selection) {
                    Text("Select…").tag("")
                    ForEach(devices) { Text($0.label).tag($0.id) }
                }
                .pickerStyle(.inline)
            }
        }
    }

    private var diskVolumes: [StorageVolume] { model.volumes.filter { !$0.path.lowercased().hasSuffix(".iso") } }
    private var isoVolumes: [StorageVolume] { model.volumes.filter { $0.path.lowercased().hasSuffix(".iso") } }

    private var isValid: Bool {
        switch category {
        case .disk:
            switch storageMode {
            case "existing": return !volumePath.isEmpty
            case "new": return !newName.isEmpty
            default: return !customPath.isEmpty
            }
        case .network: return netSel == "bridge" ? !bridge.isEmpty : !netSel.isEmpty
        case .usbhost: return !usbSel.isEmpty
        case .pcihost: return !pciSel.isEmpty
        case .filesystem: return !fsSource.isEmpty && !fsTarget.isEmpty
        default: return true
        }
    }

    private func add() {
        working = true
        Task {
            defer { working = false }
            do {
                let xml = try await buildXML()
                model.addDevice(xml: xml)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func buildXML() async throws -> String {
        switch category {
        case .disk:
            var path = customPath
            if storageMode == "existing" { path = volumePath }
            else if storageMode == "new" {
                guard let vol = await model.createVolume(pool: newPool, name: newName,
                                                         sizeGiB: newSize, format: diskFormat)
                else { throw err("Volume creation failed") }
                path = vol.path
            }
            return DeviceBuilder.disk(path: path, format: diskFormat, bus: diskBus,
                                      target: model.nextTargetDev(bus: diskBus), readOnly: false)
        case .cdrom:
            let p = volumePath.isEmpty ? customPath : volumePath
            return DeviceBuilder.cdrom(path: p, bus: cdromBus, target: model.nextTargetDev(bus: cdromBus))
        case .network:
            let kind = netSel == "bridge" ? "bridge" : "network"
            let src = netSel == "bridge" ? bridge : String(netSel.dropFirst(4))
            return DeviceBuilder.interface(sourceKind: kind, source: src, model: netModel, mac: nil)
        case .input:   return "<input type='\(inputType)' bus='\(inputBus)'/>"
        case .graphics: return gfxType == "spice"
            ? "<graphics type='spice' autoport='yes' listen='127.0.0.1'/>"
            : "<graphics type='vnc' port='-1' autoport='yes' listen='127.0.0.1'/>"
        case .video:   return "<video><model type='\(videoModel)' heads='1'/></video>"
        case .sound:   return "<sound model='\(soundModel)'/>"
        case .controller: return "<controller type='\(ctrlType)' model='\(ctrlModel)'/>"
        case .serial:  return "<serial type='pty'/>"
        case .console: return "<console type='pty'/>"
        case .channel:
            return channelTarget == "com.redhat.spice.0"
                ? DeviceBuilder.spiceChannel()
                : "<channel type='unix'>\n  <target type='virtio' name='\(channelTarget)'/>\n</channel>"
        case .usbredir: return DeviceBuilder.usbRedir()
        case .usbhost:
            guard let d = model.usbDevices.first(where: { $0.id == usbSel }) else { throw err("No device") }
            return d.hostdevXML()
        case .pcihost:
            guard let d = model.pciDevices.first(where: { $0.id == pciSel }) else { throw err("No device") }
            return d.hostdevXML()
        case .watchdog: return "<watchdog model='\(wdModel)' action='\(wdAction)'/>"
        case .tpm:      return "<tpm model='\(tpmModel)'>\n  <backend type='emulator' version='\(tpmVersion)'/>\n</tpm>"
        case .filesystem:
            return "<filesystem type='mount'>\n  <driver type='virtiofs'/>\n  <source dir='\(fsSource)'/>\n  <target dir='\(fsTarget)'/>\n</filesystem>"
        case .rng, .smartcard, .memballoon:
            return DeviceBuilder.defaultXML(for: kindFor(category)) ?? "<memballoon model='virtio'/>"
        }
    }

    private func kindFor(_ c: Category) -> DeviceKind {
        switch c {
        case .rng: return .rng
        case .smartcard: return .smartcard
        case .memballoon: return .memballoon
        default: return .other(c.rawValue)
        }
    }

    private func err(_ m: String) -> NSError {
        NSError(domain: "AddHardware", code: 1, userInfo: [NSLocalizedDescriptionKey: m])
    }
}
