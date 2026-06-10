import SwiftUI
import DomainModel
import LibvirtKit

struct NewVMSheet: View {
    @ObservedObject var session: ConnectionSession
    var onCreated: (_ uuid: String, _ openConsole: Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var step = 0
    private let steps = [
        ("Name & OS", "tag"), ("Install", "opticaldiscdrive"), ("Resources", "cpu"),
        ("Storage", "internaldrive"), ("Network", "network"), ("Review", "checkmark.seal"),
    ]
    private var lastStep: Int { steps.count - 1 }

    // Identity / OS
    @State private var name = ""
    @State private var osFamily: GuestOS.Family = .linux
    @State private var guestOS: GuestOS = .defaultOS(in: .linux)
    @State private var firmware: NewVMSpec.Firmware = .uefi
    // Resources
    @State private var memoryMiB: Double = 2048
    @State private var memoryUnit: MemoryUnit = .gib
    @State private var vcpus = 2
    @State private var graphics: NewVMSpec.Graphics = .spice
    // Network
    @State private var networkSel = ""
    @State private var bridge = ""
    // Install
    @State private var installMethod = "iso"   // iso | import | none
    @State private var isoPath = ""
    @State private var importPath = ""
    // Storage
    @State private var enableStorage = true
    @State private var storageMode = "new"      // new | existing | path
    @State private var newName = ""
    @State private var newPool = "default"
    @State private var newFormat = "qcow2"
    @State private var newSize: Double = 20
    @State private var existingDisk = ""
    @State private var customPath = ""
    // Finish
    @State private var startNow = true
    @State private var openConsole = true
    @State private var working = false
    @State private var showingUpload = false
    @State private var error: String?

    var body: some View {
        HStack(spacing: 0) {
            stepRail
            Divider()
            VStack(spacing: 0) {
                ScrollView { content.padding(24).frame(maxWidth: .infinity, alignment: .leading) }
                if let error { Text(error).foregroundStyle(.red).font(.callout).padding(.horizontal, 24) }
                Divider()
                footer
            }
        }
        .frame(width: 780, height: 560)
        .task {
            await session.loadHostResources()
            if networkSel.isEmpty { networkSel = session.networks.first?.name ?? "default" }
            if let p = session.storagePools.first { newPool = p }
        }
    }

    // MARK: - Left rail

    private var stepRail: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("New Virtual Machine").font(.headline).padding(.bottom, 8).padding(.horizontal, 4)
            ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                Button {
                    if i < step { step = i }
                } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle().fill(i == step ? Color.accentColor : (i < step ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.15)))
                                .frame(width: 22, height: 22)
                            if i < step {
                                Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(.tint)
                            } else {
                                Text("\(i + 1)").font(.caption.bold())
                                    .foregroundStyle(i == step ? .white : .secondary)
                            }
                        }
                        Text(s.0).foregroundStyle(i == step ? .primary : .secondary)
                            .fontWeight(i == step ? .semibold : .regular)
                        Spacer()
                    }
                    .padding(.vertical, 5).padding(.horizontal, 6)
                    .background(i == step ? Color.secondary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(i > step)
            }
            Spacer()
        }
        .padding(12)
        .frame(width: 200, alignment: .leading)
        .background(.quaternary.opacity(0.4))
    }

    // MARK: - Step content

    @ViewBuilder private var content: some View {
        switch step {
        case 0: nameStep
        case 1: installStep
        case 2: resourcesStep
        case 3: storageStep
        case 4: networkStep
        default: reviewStep
        }
    }

    private func stepHeader(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2).bold()
            Text(subtitle).foregroundStyle(.secondary)
        }
        .padding(.bottom, 6)
    }

    private var nameStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader("Name your virtual machine", "Pick a name and the guest operating system.")
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 14) {
                GridRow { Text("Name").gridColumnAlignment(.trailing); TextField("my-vm", text: $name).frame(width: 240) }
                if !name.isEmpty && !nameValid {
                    GridRow { Color.clear.frame(width: 0); Label("A VM with this name already exists", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                }
                GridRow { Text("OS type"); Picker("", selection: $osFamily) { ForEach(GuestOS.Family.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().fixedSize().frame(width: 240, alignment: .leading) }
                GridRow { Text("Version"); Picker("", selection: $guestOS) { ForEach(GuestOS.all(in: osFamily)) { Text($0.name).tag($0) } }.labelsHidden().fixedSize().frame(width: 240, alignment: .leading) }
                GridRow { Text("Firmware"); Picker("", selection: $firmware) { ForEach(NewVMSpec.Firmware.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().pickerStyle(.segmented).fixedSize().frame(width: 240, alignment: .leading).disabled(guestOS.requiresUEFI) }
            }
            Text("Tuned for \(guestOS.name): \(guestOS.tuningSummary)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: osFamily) { _, fam in guestOS = .defaultOS(in: fam) }
        .onChange(of: guestOS) { _, os in
            // Pre-fill recommended resources; the user can still change them.
            memoryMiB = Double(os.memoryMiB)
            vcpus = os.vcpus
            newSize = Double(os.diskGiB)
            if os.requiresUEFI { firmware = .uefi }
        }
    }

    private var installStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader("How do you want to install the OS?", "Boot an installer ISO, import an existing disk, or set up later.")
            HStack(spacing: 12) {
                InstallCard(symbol: "opticaldiscdrive", title: "Local ISO", subtitle: "Boot an installer", selected: installMethod == "iso") { installMethod = "iso" }
                InstallCard(symbol: "internaldrive", title: "Import disk", subtitle: "Existing image", selected: installMethod == "import") { installMethod = "import" }
                InstallCard(symbol: "square.dashed", title: "No media", subtitle: "Manual / later", selected: installMethod == "none") { installMethod = "none" }
            }
            if installMethod == "iso" {
                volumePicker(title: "ISO image", binding: $isoPath, volumes: isoVolumes, prompt: "/path/to.iso")
            } else if installMethod == "import" {
                volumePicker(title: "Disk image", binding: $importPath, volumes: diskVolumes, prompt: "/path/to/disk.qcow2")
            }
        }
    }

    private var resourcesStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader("Allocate resources", "How much CPU and memory should this VM get?")
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 18) {
                GridRow {
                    Text("CPUs").gridColumnAlignment(.trailing)
                    HStack(spacing: 6) {
                        TextField("", value: $vcpus, format: .number)
                            .multilineTextAlignment(.trailing).frame(width: 90)
                            .onChange(of: vcpus) { _, n in vcpus = min(max(n, 1), 256) }
                        Stepper("", value: $vcpus, in: 1...256).labelsHidden()
                        Text("vCPU").foregroundStyle(.secondary)
                    }
                }
                GridRow { Text("Memory"); MemoryAmountField(mib: $memoryMiB, unit: $memoryUnit) }
            }
        }
    }

    private var storageStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader("Storage", installMethod == "import" ? "This VM boots the imported disk." : "Create a virtual disk or attach an existing one.")
            if installMethod == "import" {
                Label(importPath, systemImage: "internaldrive").foregroundStyle(.secondary)
            } else {
                Toggle("Create a disk for this VM", isOn: $enableStorage)
                if enableStorage {
                    Picker("", selection: $storageMode) {
                        Text("Create new volume").tag("new")
                        Text("Use existing volume").tag("existing")
                        Text("File path").tag("path")
                    }.labelsHidden().pickerStyle(.segmented).frame(width: 380)
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                        switch storageMode {
                        case "new":
                            GridRow { Text("Name").gridColumnAlignment(.trailing); TextField(name.isEmpty ? "disk" : name, text: $newName).frame(width: 220) }
                            GridRow { Text("Pool"); Picker("", selection: $newPool) { ForEach(session.storagePools, id: \.self) { Text($0) } }.labelsHidden().fixedSize().frame(width: 220, alignment: .leading) }
                            GridRow { Text("Format"); Picker("", selection: $newFormat) { Text("qcow2").tag("qcow2"); Text("raw").tag("raw") }.labelsHidden().fixedSize().frame(width: 120, alignment: .leading) }
                            GridRow { Text("Size (GiB)"); TextField("", value: $newSize, format: .number).multilineTextAlignment(.trailing).frame(width: 90, alignment: .leading) }
                        case "existing":
                            GridRow { Text("Volume"); Picker("", selection: $existingDisk) { Text("Select…").tag(""); ForEach(diskVolumes) { Text($0.name).tag($0.path) } }.labelsHidden().fixedSize().frame(width: 280, alignment: .leading) }
                        default:
                            GridRow { Text("Path"); TextField("/var/lib/libvirt/images/disk.qcow2", text: $customPath).frame(width: 320) }
                        }
                    }
                }
            }
        }
    }

    private var networkStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader("Network & display", "Connect the VM and choose its graphical console.")
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 14) {
                GridRow {
                    Text("Network").gridColumnAlignment(.trailing)
                    Picker("", selection: $networkSel) {
                        ForEach(session.networks) { Text("Virtual network: \($0.name)").tag($0.name) }
                        Text("Bridge device…").tag("__bridge__")
                    }.labelsHidden().fixedSize().frame(width: 280, alignment: .leading)
                }
                if networkSel == "__bridge__" {
                    GridRow { Text("Bridge"); TextField("br0", text: $bridge).frame(width: 160) }
                }
                GridRow {
                    Text("Display")
                    Picker("", selection: $graphics) { ForEach(NewVMSpec.Graphics.allCases) { Text($0.rawValue).tag($0) } }
                        .labelsHidden().pickerStyle(.segmented).fixedSize().frame(width: 160, alignment: .leading)
                }
            }
        }
    }

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader("Ready to create", "Review the configuration, then create the VM.")
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                summaryRow("Name", name)
                summaryRow("OS / Firmware", "\(guestOS.name) · \(firmware.rawValue)")
                summaryRow("Install", installSummary)
                summaryRow("CPU / Memory", "\(vcpus) vCPU · \(memoryLabel(mib: memoryMiB))")
                summaryRow("Storage", storageSummary)
                summaryRow("Network", networkSel == "__bridge__" ? "bridge \(bridge)" : networkSel)
                summaryRow("Display", graphics.rawValue)
            }
            Divider().padding(.vertical, 4)
            Toggle("Start now", isOn: $startNow)
            Toggle("Open console after creating", isOn: $openConsole).disabled(!startNow)
            if installMethod == "iso" {
                Label("After the OS installs, eject the ISO via Hardware → CD-ROM so it boots from disk.",
                      systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Spacer()
            if step > 0 { Button("Back") { step -= 1 } }
            if step < lastStep {
                Button("Continue") { step += 1 }.keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).disabled(!canAdvance)
            } else {
                Button(working ? "Creating…" : "Create VM") { create() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(working || !canCreate)
            }
        }
        .padding(16)
    }

    // MARK: - Reusable pieces

    private func volumePicker(title: String, binding: Binding<String>, volumes: [StorageVolume], prompt: String) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
            GridRow {
                Text(title).gridColumnAlignment(.trailing)
                HStack(spacing: 8) {
                    Picker("", selection: binding) {
                        Text("Select…").tag("")
                        ForEach(volumes) { Text($0.name).tag($0.path) }
                    }.labelsHidden().fixedSize().frame(width: 240, alignment: .leading)
                    Button("Upload ISO…") { showingUpload = true }
                        .help("Upload an ISO from this Mac to the host")
                }
            }
            GridRow { Text("Or path"); TextField(prompt, text: binding).frame(width: 320) }
        }
        .sheet(isPresented: $showingUpload) {
            UploadISOSheet(session: session) { path in
                binding.wrappedValue = path
            }
        }
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value.isEmpty ? "—" : value)
        }
    }

    private var installSummary: String {
        switch installMethod {
        case "iso": return "ISO: \((isoPath as NSString).lastPathComponent)"
        case "import": return "Import: \((importPath as NSString).lastPathComponent)"
        default: return "No media"
        }
    }
    private var storageSummary: String {
        if installMethod == "import" { return "imported disk" }
        guard enableStorage else { return "none" }
        switch storageMode {
        case "new": return "new \(Int(newSize)) GiB \(newFormat) on \(newPool)"
        case "existing": return (existingDisk as NSString).lastPathComponent
        default: return (customPath as NSString).lastPathComponent
        }
    }

    // MARK: - Validation

    private var nameValid: Bool { !name.isEmpty && !session.domains.contains { $0.name == name } }
    private var canAdvance: Bool {
        switch step {
        case 0: return nameValid
        case 1:
            if installMethod == "iso" { return !isoPath.isEmpty }
            if installMethod == "import" { return !importPath.isEmpty }
            return true
        case 3:
            if installMethod == "import" { return !importPath.isEmpty }
            if !enableStorage { return true }
            switch storageMode {
            case "new": return !(newName.isEmpty && name.isEmpty)
            case "existing": return !existingDisk.isEmpty
            default: return !customPath.isEmpty
            }
        case 4: return networkSel == "__bridge__" ? !bridge.isEmpty : !networkSel.isEmpty
        default: return true
        }
    }
    private var canCreate: Bool { nameValid }

    private var isoVolumes: [StorageVolume] { session.volumes.filter { $0.path.lowercased().hasSuffix(".iso") } }
    private var diskVolumes: [StorageVolume] { session.volumes.filter { !$0.path.lowercased().hasSuffix(".iso") } }

    // MARK: - Create (unchanged logic)

    private func create() {
        working = true; error = nil
        Task {
            defer { working = false }
            var diskPath: String?
            if installMethod == "import" {
                diskPath = importPath
            } else if enableStorage {
                switch storageMode {
                case "new":
                    let volName = newName.isEmpty ? name : newName
                    guard let vol = await session.createVolume(pool: newPool, name: volName,
                        capacityBytes: UInt64(max(1, newSize) * 1024 * 1024 * 1024), format: newFormat)
                    else { error = session.lastError ?? "Failed to create disk"; return }
                    diskPath = vol.path
                case "existing": diskPath = existingDisk
                default: diskPath = customPath
                }
            }

            let install: NewVMSpec.Install =
                installMethod == "iso" ? .iso(isoPath) :
                installMethod == "import" ? .importDisk : .none
            let netSource = networkSel == "__bridge__" ? "bridge:\(bridge)" : networkSel
            let spec = NewVMSpec(name: name, os: guestOS, firmware: firmware,
                                 memoryMiB: Int(memoryMiB), vcpus: vcpus, install: install,
                                 diskPath: diskPath, networkSource: netSource, graphics: graphics)
            let caps = session.domainCaps
            let xml = DomainTemplate.buildXML(spec, domainType: caps.domainType,
                                              emulator: caps.emulator, arch: caps.arch)
            guard let uuid = await session.createDomain(xml: xml) else {
                error = session.lastError ?? "Failed to define the VM"; return
            }
            if startNow { await session.perform(.start, on: uuid) }
            onCreated(uuid, startNow && openConsole)
            dismiss()
        }
    }
}

private struct InstallCard: View {
    let symbol: String, title: String, subtitle: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 28))
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                Text(title).fontWeight(.semibold)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 130, height: 110)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
    }
}
