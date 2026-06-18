import SwiftUI
import DomainModel

enum HardwareSelection: Hashable {
    case general, cpus, memory, boot
    case device(String)
}

struct HardwareTab: View {
    @ObservedObject var session: ConnectionSession
    let uuid: String

    @StateObject private var model: HardwareModel
    @State private var selection: HardwareSelection? = .general
    @State private var showingAdd = false
    @State private var showingConfigDiff = false
    @State private var confirmRemove: Device?

    init(session: ConnectionSession, uuid: String) {
        self.session = session
        self.uuid = uuid
        _model = StateObject(wrappedValue: HardwareModel(session: session, uuid: uuid))
    }

    var body: some View {
        Group {
            if model.isLoaded {
                VStack(spacing: 0) {
                    if model.liveDiffersFromSaved { configSyncBanner }
                    HSplitView {
                        sidebar.frame(minWidth: 220, idealWidth: 250, maxWidth: 320)
                        detail.frame(minWidth: 360, maxWidth: .infinity)
                    }
                }
            } else if let e = model.loadError {
                ContentUnavailableView("Couldn't Load Hardware", systemImage: "exclamationmark.triangle",
                                       description: Text(e))
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .task(id: uuid) { if !model.isLoaded { await model.load() } }
        .onChange(of: session.configDrift[uuid]) { _, _ in
            Task { await model.refreshConfigSyncState() }
        }
        .safeAreaInset(edge: .bottom) {
            if model.dirty || model.applyMessage != nil { applyBar }
        }
        .sheet(isPresented: $showingAdd) { AddHardwareSheet(model: model) }
        .sheet(isPresented: $showingConfigDiff) { ConfigDiffSheet(model: model) }
        .confirmationDialog(
            "Remove \(confirmRemove?.title ?? "device")?",
            isPresented: Binding(get: { confirmRemove != nil },
                                 set: { if !$0 { confirmRemove = nil } }),
            titleVisibility: .visible,
            presenting: confirmRemove
        ) { d in
            if model.isRunning && HardwareModel.isHotpluggable(d.kind) {
                Button("Detach Now (live)", role: .destructive) {
                    Task { if await model.detachDeviceLive(id: d.id) { selection = .general } }
                    confirmRemove = nil
                }
                Button("Remove After Restart", role: .destructive) {
                    model.removeDevice(id: d.id)
                    selection = .general
                    confirmRemove = nil
                }
            } else {
                Button("Remove \(d.title)", role: .destructive) {
                    model.removeDevice(id: d.id)
                    selection = .general
                    confirmRemove = nil
                }
            }
        } message: { d in
            Text(removeMessage(d))
        }
    }

    private func removeMessage(_ d: Device) -> String {
        var lines: [String] = []
        if case .warning(let reason) = d.removability { lines.append(reason) }
        lines.append("The device is removed when you click Apply Changes and takes effect after the VM restarts.")
        return lines.joined(separator: "\n")
    }

    private var configSyncBanner: some View {
        HStack(spacing: 12) {
            Label("Running configuration differs from saved",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
            Spacer()
            Button("View diff…") { showingConfigDiff = true }
            Button("Revert to saved") {
                Task { await model.revertLiveToSaved() }
            }
            .disabled(model.applying)
            Button("Update saved from running") {
                Task { await model.syncSavedFromLive() }
            }
            .disabled(model.applying)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section("System") {
                    Label("General", systemImage: "info.circle").tag(HardwareSelection.general)
                    Label("CPUs", systemImage: "cpu").tag(HardwareSelection.cpus)
                    Label("Memory", systemImage: "memorychip").tag(HardwareSelection.memory)
                    Label("Boot Options", systemImage: "power").tag(HardwareSelection.boot)
                }
                Section("Devices") {
                    ForEach(model.devices) { d in
                        deviceRow(d)
                            .tag(HardwareSelection.device(d.id))
                            .contextMenu { removeMenuItems(d) }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            HStack(spacing: 8) {
                Button { showingAdd = true } label: {
                    Label("Add Hardware…", systemImage: "plus")
                }
                .help("Add a new device to this VM")
                Spacer()
                Button {
                    if let d = selectedDevice { confirmRemove = d }
                } label: { Image(systemName: "minus") }
                    .help(removeButtonHelp)
                    .disabled(!(selectedDevice?.removable ?? false))
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
    }

    @ViewBuilder private func removeMenuItems(_ d: Device) -> some View {
        if case .blocked(let reason) = d.removability {
            Button("Cannot remove — \(reason)") {}.disabled(true)
        } else {
            Button("Remove \(d.title)…", role: .destructive) { confirmRemove = d }
        }
    }

    private func deviceRow(_ d: Device) -> some View {
        HStack(spacing: 8) {
            Image(systemName: d.kind.symbol).frame(width: 18).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(d.title)
                if !d.subtitle.isEmpty {
                    Text(d.subtitle).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }

    private var selectedDevice: Device? {
        if case .device(let id)? = selection {
            return model.devices.first { $0.id == id }
        }
        return nil
    }

    private var removeButtonHelp: String {
        guard let d = selectedDevice else { return "Select a device to remove it" }
        if case .blocked(let reason) = d.removability { return reason }
        return "Remove \(d.title)…"
    }

    // MARK: - Detail

    @ViewBuilder private var detail: some View {
        switch selection {
        case .general: GeneralEditor(model: model)
        case .cpus:   CPUsEditor(model: model)
        case .memory: MemoryEditor(model: model)
        case .boot:   BootEditor(model: model)
        case .device(let id):
            if let d = model.devices.first(where: { $0.id == id }) {
                DeviceFormView(model: model, device: d) { confirmRemove = $0 }
            } else {
                ContentUnavailableView("Device removed", systemImage: "trash")
            }
        case nil:
            ContentUnavailableView("Select hardware", systemImage: "cpu")
        }
    }

    private var applyBar: some View {
        HStack {
            if let msg = model.applyMessage {
                Label(msg, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            } else {
                Label("Unsaved changes", systemImage: "pencil.circle.fill").foregroundStyle(.orange)
            }
            Spacer()
            Button("Revert") { model.revert() }.disabled(!model.dirty || model.applying)
            Button(model.applying ? "Applying…" : "Apply Changes") { Task { await model.apply() } }
                .buttonStyle(.borderedProminent)
                .disabled(!model.dirty || model.applying)
        }
        .padding(10)
        .background(.bar)
    }
}
