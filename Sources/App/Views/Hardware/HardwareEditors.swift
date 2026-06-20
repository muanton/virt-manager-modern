import SwiftUI
import DomainModel

private struct StagedNote: View {
    var body: some View {
        Text("Edits are staged. Click **Apply Changes** to save; they take effect after the VM restarts.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

struct GeneralEditor: View {
    @ObservedObject var model: HardwareModel
    @State private var title = ""
    @State private var desc = ""
    @State private var autostart = false

    var body: some View {
        Form {
            Section("General") {
                LabeledContent("Name", value: model.vmName)
                LabeledContent("UUID", value: model.uuid).textSelection(.enabled)
                    .font(.callout.monospaced())
                LabeledContent("Title") {
                    TextField("optional", text: $title).onSubmit { model.setTitle(title) }
                }
                VStack(alignment: .leading) {
                    Text("Description").foregroundStyle(.secondary)
                    TextField("optional", text: $desc, axis: .vertical)
                        .lineLimit(2...5).onSubmit { model.setDescription(desc) }
                }
                Toggle("Start automatically on host boot", isOn: $autostart)
                    .onChange(of: autostart) { _, on in Task { _ = await model.setAutostart(on) } }
            }
            Section("Hypervisor") {
                LabeledContent("Hypervisor", value: model.domainType.uppercased())
                LabeledContent("Architecture", value: model.arch)
                LabeledContent("Emulator", value: model.emulator)
                chipsetRow
                firmwareRow
            }
            Section { StagedNote() }
        }
        .formStyle(.grouped)
        .textFieldStyle(.roundedBorder)
        .onAppear {
            title = model.title; desc = model.desc
            Task { autostart = await model.loadAutostart() }
        }
        // Stage title/description on focus loss too (not just Return).
        .onDisappear { model.setTitle(title); model.setDescription(desc) }
    }

    @ViewBuilder private var chipsetRow: some View {
        Picker("Chipset", selection: Binding(
            get: { model.chipsetIsQ35 },
            set: { model.setChipset(q35: $0) })) {
            Text("Q35 (modern)").tag(true)
            Text("i440FX (legacy)").tag(false)
        }
        Text("Switching chipset rebuilds the virtual PCI layout; the guest may need driver or boot "
           + "changes. Takes effect after restart.")
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private var firmwareRow: some View {
        Picker("Firmware", selection: Binding(
            get: { model.firmwareIsEFI },
            set: { model.setFirmware(efi: $0) })) {
            Text("BIOS").tag(false)
            Text("UEFI").tag(true)
        }
        if model.firmwareChangeRisky {
            Label("This VM already has a disk installed — switching firmware will likely stop it "
                + "from booting. Takes effect after restart.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        }
    }
}

struct CPUsEditor: View {
    @ObservedObject var model: HardwareModel
    @State private var vcpu = 1
    @State private var mode = ""
    @State private var customModel = ""
    @State private var topoEnabled = false
    @State private var sockets = 1
    @State private var cores = 1
    @State private var threads = 1

    private let modes = [
        ("", "Hypervisor default"), ("host-passthrough", "Copy host CPU (passthrough)"),
        ("host-model", "Host model"), ("maximum", "Maximum"), ("custom", "Custom"),
    ]

    var body: some View {
        Form {
            Section("Allocation") {
                LabeledContent("vCPUs") {
                    HStack(spacing: 6) {
                        TextField("", value: $vcpu, format: .number)
                            .multilineTextAlignment(.trailing).frame(width: 90)
                        Stepper("", value: $vcpu, in: 1...256).labelsHidden()
                    }
                }
                .onChange(of: vcpu) { _, n in
                    let clamped = min(max(n, 1), 256)
                    if clamped != n { vcpu = clamped }
                    if clamped != model.vcpu { model.setCPU(clamped) }
                }
                if model.isRunning {
                    Button("Apply to Running VM") {
                        Task { await model.applyVcpusLive(vcpu) }
                    }
                    .disabled(model.applying)
                    .help("Change the vCPU count live (within the configured maximum)")
                }
            }
            Section("Configuration") {
                Picker("Mode", selection: $mode) {
                    ForEach(modes, id: \.0) { Text($0.1).tag($0.0) }
                }
                .onChange(of: mode) { _, m in model.setCPUMode(m) }
                if mode == "custom" {
                    LabeledContent("Model") {
                        TextField("e.g. Skylake-Client", text: $customModel)
                            .onSubmit { model.setCPUModel(customModel) }
                    }
                }
            }
            Section("Topology") {
                Toggle("Manually set CPU topology", isOn: $topoEnabled)
                    .onChange(of: topoEnabled) { _, on in pushTopology(enabled: on) }
                if topoEnabled {
                    Stepper("Sockets: \(sockets)", value: $sockets, in: 1...64).onChange(of: sockets) { _, _ in pushTopology(enabled: true) }
                    Stepper("Cores: \(cores)", value: $cores, in: 1...256).onChange(of: cores) { _, _ in pushTopology(enabled: true) }
                    Stepper("Threads: \(threads)", value: $threads, in: 1...8).onChange(of: threads) { _, _ in pushTopology(enabled: true) }
                    Text("\(sockets) × \(cores) × \(threads) = \(sockets*cores*threads) logical CPUs")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section { StagedNote() }
        }
        .formStyle(.grouped)
        .textFieldStyle(.roundedBorder)
        .onAppear {
            vcpu = model.vcpu
            mode = model.cpuMode
            customModel = model.cpuModelName
            if let t = model.cpuTopology { topoEnabled = true; sockets = t.sockets; cores = t.cores; threads = t.threads }
        }
    }

    private func pushTopology(enabled: Bool) {
        model.setCPUTopology(enabled ? (sockets, cores, threads) : nil)
    }
}

struct MemoryEditor: View {
    @ObservedObject var model: HardwareModel
    @State private var current: Double = 0
    @State private var maximum: Double = 0
    @State private var unit: MemoryUnit = .gib

    var body: some View {
        Form {
            Section("Memory") {
                LabeledContent("Current") {
                    MemoryAmountField(mib: $current, unit: $unit) { stage() }
                }
                LabeledContent("Maximum") {
                    MemoryAmountField(mib: $maximum, unit: $unit) { stage() }
                }
                Button("Update Memory") { stage() }
                if model.isRunning {
                    Button("Apply to Running VM") {
                        Task { await model.applyMemoryLive(currentMiB: current) }
                    }
                    .disabled(model.applying)
                    .help("Resize the guest's memory balloon live (up to the configured maximum)")
                }
            }
            Section { StagedNote() }
        }
        .formStyle(.grouped)
        .textFieldStyle(.roundedBorder)
        .onAppear { current = model.currentMemoryMiB; maximum = model.maxMemoryMiB }
    }

    private func stage() { model.setMemory(currentMiB: current, maxMiB: maximum) }
}

struct BootEditor: View {
    @ObservedObject var model: HardwareModel
    @State private var order: [String] = []
    @State private var bootMenu = false
    private let known = ["hd", "cdrom", "network", "fd"]

    var body: some View {
        Form {
            Section("Boot Order") {
                List {
                    ForEach(order, id: \.self) { dev in
                        HStack {
                            Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
                            Text(label(dev))
                        }
                    }
                    .onMove { idx, dest in
                        order.move(fromOffsets: idx, toOffset: dest)
                        model.setBootOrder(order)
                    }
                }
                .frame(minHeight: 120)
            }
            Section("Devices") {
                ForEach(known, id: \.self) { dev in
                    Toggle(label(dev), isOn: Binding(
                        get: { order.contains(dev) },
                        set: { on in
                            if on { if !order.contains(dev) { order.append(dev) } }
                            else { order.removeAll { $0 == dev } }
                            model.setBootOrder(order)
                        }))
                }
            }
            Section("Options") {
                Toggle("Enable boot menu", isOn: $bootMenu)
                    .onChange(of: bootMenu) { _, b in model.setBootMenu(b) }
            }
            Section { StagedNote() }
        }
        .formStyle(.grouped)
        .textFieldStyle(.roundedBorder)
        .onAppear { order = model.bootDevices; bootMenu = model.bootMenu }
    }

    private func label(_ d: String) -> String {
        switch d {
        case "hd": return "Hard Disk"
        case "cdrom": return "CD-ROM"
        case "network": return "Network (PXE)"
        case "fd": return "Floppy"
        default: return d
        }
    }
}
