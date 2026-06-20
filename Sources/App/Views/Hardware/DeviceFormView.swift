import SwiftUI
import DomainModel
import LibvirtKit

/// Renders a device's editable fields from `DeviceSchema`, bound to the working
/// copy. No raw XML — every field is a proper control.
struct DeviceFormView: View {
    @ObservedObject var model: HardwareModel
    let device: Device
    /// Invoked when the user asks to remove this device (HardwareTab presents
    /// the confirmation). Nil hides the Remove section.
    var onRemove: ((Device) -> Void)? = nil

    private var fields: [DeviceField] { DeviceSchema.fields(for: device.kind) }

    var body: some View {
        Form {
            Section(device.kind.label) {
                if fields.isEmpty {
                    Text("This device has no editable properties.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(fields) { fieldRow($0) }
                }
            }
            if onRemove != nil { removeSection }
            Section {
                Text(device.kind == .cdrom
                     ? "Edits are staged — **Apply Changes** saves the ISO and inserts it into a running VM immediately."
                     : "Edits are staged — click **Apply Changes** to save; they take effect after the VM restarts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .textFieldStyle(.roundedBorder)
        .navigationTitle(device.title)
        .task { await model.loadHostResources() }
    }

    @ViewBuilder private var removeSection: some View {
        Section {
            switch device.removability {
            case .blocked(let reason):
                Label(reason, systemImage: "lock")
                    .font(.callout).foregroundStyle(.secondary)
            case .warning(let reason):
                VStack(alignment: .leading, spacing: 6) {
                    Button(role: .destructive) { onRemove?(device) } label: {
                        Label("Remove Device…", systemImage: "trash")
                    }
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            case .ok:
                Button(role: .destructive) { onRemove?(device) } label: {
                    Label("Remove Device…", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder private func fieldRow(_ field: DeviceField) -> some View {
        switch field.control {
        case .text(let ph):
            labeled(field) {
                TextField(ph, text: strBinding(field))
                    .frame(maxWidth: 280)
            }
        case .menu(let opts):
            menuRow(field, opts)
        case .toggle:
            Toggle(field.label, isOn: boolBinding(field))
        case .int(let lo, _):
            labeled(field) {
                TextField("", value: intBinding(field, fallback: lo), format: .number)
                    .frame(width: 100).multilineTextAlignment(.trailing)
            }
        case .autoPort:
            AutoPortRow(model: model, device: device, field: field)
        case .networkSource:
            NetworkSourceRow(model: model, device: device)
        case .storageVolume(let iso):
            StorageSourceRow(model: model, device: device, isISO: iso)
        case .hostDevice:
            LabeledContent(field.label, value: device.kind == .hostdev ? "Passthrough host device" : "—")
        case .readonly:
            LabeledContent(field.label, value: nonEmpty(model.fieldString(device.id, field.locator)))
        }
    }

    private func labeled(_ field: DeviceField, @ViewBuilder _ content: () -> some View) -> some View {
        LabeledContent(field.label) { content() }
    }

    private func menuRow(_ field: DeviceField, _ opts: [MenuOption]) -> some View {
        let cur = model.fieldString(device.id, field.locator)
        var options = opts
        if !cur.isEmpty && !options.contains(where: { $0.value == cur }) {
            options.insert(MenuOption(cur), at: 0)
        }
        return Picker(field.label, selection: strBinding(field)) {
            ForEach(options, id: \.value) { Text($0.label).tag($0.value) }
        }
    }

    private func strBinding(_ field: DeviceField) -> Binding<String> {
        Binding(get: { model.fieldString(device.id, field.locator) },
                set: { model.setField(device.id, field.locator, string: $0.isEmpty ? nil : $0) })
    }
    private func boolBinding(_ field: DeviceField) -> Binding<Bool> {
        Binding(get: { model.fieldBool(device.id, field.locator) },
                set: { model.setField(device.id, field.locator, bool: $0) })
    }
    private func intBinding(_ field: DeviceField, fallback: Int) -> Binding<Int> {
        Binding(get: { Int(model.fieldString(device.id, field.locator)) ?? fallback },
                set: { model.setField(device.id, field.locator, string: String($0)) })
    }
    private func nonEmpty(_ s: String) -> String { s.isEmpty ? "—" : s }
}

// MARK: - Graphics port (auto / manual)

private struct AutoPortRow: View {
    @ObservedObject var model: HardwareModel
    let device: Device
    let field: DeviceField

    private var isAuto: Bool {
        let port = model.fieldString(device.id, field.locator)
        return model.fieldString(device.id, .attr("autoport")) == "yes" || port.isEmpty || port == "-1"
    }

    var body: some View {
        Toggle("Auto-assign port", isOn: Binding(get: { isAuto }, set: { on in
            if on {
                model.setField(device.id, .attr("autoport"), string: "yes")
                model.setField(device.id, field.locator, string: nil)
            } else {
                model.setField(device.id, .attr("autoport"), string: "no")
                model.setField(device.id, field.locator, string: "5900")
            }
        }))
        if !isAuto {
            LabeledContent("Port") {
                TextField("", value: Binding(
                    get: { Int(model.fieldString(device.id, field.locator)) ?? 5900 },
                    set: { model.setField(device.id, field.locator, string: String($0)) }),
                    format: .number)
                .frame(width: 100).multilineTextAlignment(.trailing)
            }
        }
    }
}

// MARK: - Network source

private struct NetworkSourceRow: View {
    @ObservedObject var model: HardwareModel
    let device: Device
    @State private var bridge = ""

    private var nic: NICInfo? { model.nic(id: device.id) }
    private var isBridge: Bool { nic?.type == "bridge" }

    private var selection: Binding<String> {
        Binding(
            get: { isBridge ? "__bridge__" : "net:\(nic?.source ?? "")" },
            set: { val in
                if val == "__bridge__" {
                    model.setInterfaceSource(device.id, type: "bridge", source: bridge)
                } else {
                    model.setInterfaceSource(device.id, type: "network", source: String(val.dropFirst(4)))
                }
            })
    }

    var body: some View {
        Picker("Network Source", selection: selection) {
            ForEach(model.networks) { net in
                Text("Virtual network: \(net.name)").tag("net:\(net.name)")
            }
            Text("Bridge device…").tag("__bridge__")
        }
        if isBridge {
            LabeledContent("Bridge") {
                TextField("br0", text: Binding(
                    get: { nic?.source ?? bridge },
                    set: { bridge = $0; model.setInterfaceSource(device.id, type: "bridge", source: $0) }))
            }
        }
    }
}

// MARK: - Storage source (existing volume / path / create new)

private struct StorageSourceRow: View {
    @ObservedObject var model: HardwareModel
    let device: Device
    let isISO: Bool

    @State private var creating = false
    @State private var newName = ""
    @State private var newSizeGiB: Double = 20
    @State private var newFormat = "qcow2"
    @State private var newPool = "default"
    @State private var working = false

    private var current: String { model.disk(id: device.id)?.source ?? "" }
    private var matchingVolumes: [StorageVolume] {
        model.volumes.filter { isISO ? $0.path.lowercased().hasSuffix(".iso")
                                      : !$0.path.lowercased().hasSuffix(".iso") }
    }

    var body: some View {
        Picker(isISO ? "ISO Image" : "Storage", selection: Binding(
            get: { current },
            set: { if !$0.isEmpty { model.setDiskSource(device.id, path: $0) } })) {
            if current.isEmpty { Text("None").tag("") }
            ForEach(matchingVolumes) { vol in
                Text("\(vol.name)  (\(vol.pool))").tag(vol.path)
            }
            if !current.isEmpty && !matchingVolumes.contains(where: { $0.path == current }) {
                Text(current).tag(current)
            }
        }
        LabeledContent("Path") {
            TextField("/var/lib/libvirt/images/…", text: Binding(
                get: { current },
                set: { model.setDiskSource(device.id, path: $0) }))
        }
        if isISO {
            LabeledContent("Media") {
                Button {
                    Task { await model.ejectCDROM(device.id) }
                } label: {
                    Label("Eject", systemImage: "eject")
                }
                .disabled(current.isEmpty || model.applying)
            }
        }
        if !isISO {
            DisclosureGroup("Create new disk image", isExpanded: $creating) {
                LabeledContent("Name") { TextField("disk", text: $newName) }
                Picker("Pool", selection: $newPool) {
                    ForEach(model.storagePools, id: \.self) { Text($0) }
                }
                Picker("Format", selection: $newFormat) {
                    Text("qcow2").tag("qcow2"); Text("raw").tag("raw")
                }
                LabeledContent("Size (GiB)") {
                    TextField("", value: $newSizeGiB, format: .number).frame(width: 80)
                        .multilineTextAlignment(.trailing)
                }
                Button(working ? "Creating…" : "Create & Attach") { create() }
                    .disabled(working || newName.isEmpty)
            }
        }
    }

    private func create() {
        working = true
        Task {
            defer { working = false }
            if let vol = await model.createVolume(pool: newPool, name: newName,
                                                  sizeGiB: newSizeGiB, format: newFormat) {
                model.setDiskSource(device.id, path: vol.path)
                creating = false
            }
        }
    }
}
