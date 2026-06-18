import SwiftUI
import LibvirtKit
import ConsoleKit
import SpiceKit

struct DomainDetailView: View {
    @ObservedObject var session: ConnectionSession
    let uuid: String
    var openConsoleOnce: Binding<Bool> = .constant(false)
    var onDelete: (DomainSummary) -> Void = { _ in }
    var onClone: (DomainSummary) -> Void = { _ in }

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var preferences: AppPreferences
    @State private var confirmForceOff = false
    @State private var confirmSave = false
    @State private var confirmDiscardSave = false
    @State private var confirmDriftPower = false
    @State private var pendingDriftAction: DomainAction?
    @State private var hasManagedSave = false
    @State private var lifecycleError: String?
    @State private var tab = 0

    @StateObject private var vnc = VNCSession()
    @StateObject private var spice = SpiceConsoleSession()

    private var domain: DomainSummary? { session.domain(uuid: uuid) }
    private var tabKey: String { "\(session.id)/\(uuid)" }

    var body: some View {
        Group {
            if let domain {
                TabView(selection: $tab) {
                    OverviewTab(session: session, domain: domain)
                        .tabItem { Label("Overview", systemImage: "info.circle") }.tag(0)
                    ConsoleTab(session: session, domain: domain, vnc: vnc, spice: spice)
                        .tabItem { Label("Console", systemImage: "display") }.tag(1)
                    HardwareTab(session: session, uuid: uuid)
                        .tabItem { Label("Hardware", systemImage: "slider.horizontal.3") }.tag(2)
                    SnapshotsTab(session: session, domain: domain)
                        .tabItem { Label("Snapshots", systemImage: "camera") }.tag(3)
                }
                .padding()
                .navigationTitle(domain.name)
                .navigationSubtitle(subtitle(for: domain))
                .toolbar { lifecycleToolbar(domain) }
                .toolbarBackground(.visible, for: .windowToolbar)
                .background { lifecycleShortcuts(domain) }
                .confirmationDialog("Force off \(domain.name)? Unsaved data may be lost.",
                                    isPresented: $confirmForceOff, titleVisibility: .visible) {
                    Button("Force Off", role: .destructive) { performLifecycle(.forceOff) }
                }
                .confirmationDialog(
                    "Save \(domain.name) to disk? The VM will shut down and its memory state is stored on the host.",
                    isPresented: $confirmSave, titleVisibility: .visible) {
                    Button("Save") { performLifecycle(.save) }
                }
                .confirmationDialog(
                    "Discard saved state for \(domain.name)? The next start will boot fresh.",
                    isPresented: $confirmDiscardSave, titleVisibility: .visible) {
                    Button("Discard", role: .destructive) { discardSave() }
                }
                .confirmationDialog(
                    "Running configuration differs from saved for \(domain.name). Unsaved live changes are lost on the next boot.",
                    isPresented: $confirmDriftPower, titleVisibility: .visible) {
                    if let action = pendingDriftAction {
                        Button(driftConfirmTitle(action), role: driftConfirmDestructive(action) ? .destructive : nil) {
                            performLifecycle(action)
                        }
                    }
                    Button("Cancel", role: .cancel) { pendingDriftAction = nil }
                }
                .task(id: "\(uuid)-\(domain.state.rawValue)") { await refreshManagedSave() }
                .alert("Operation Failed", isPresented: Binding(
                    get: { lifecycleError != nil },
                    set: { if !$0 { lifecycleError = nil } })) {
                    Button("OK", role: .cancel) { lifecycleError = nil }
                } message: {
                    Text(lifecycleError ?? "")
                }
            } else {
                ContentUnavailableView("VM Unavailable", systemImage: "questionmark.folder")
            }
        }
        .onDisappear { vnc.stop(); spice.stop() }
        .onAppear {
            if openConsoleOnce.wrappedValue {
                tab = 1
                openConsoleOnce.wrappedValue = false
            } else {
                tab = appState.detailTabs[tabKey] ?? preferences.defaultDetailTab
            }
        }
        .onChange(of: tab) { _, newValue in appState.detailTabs[tabKey] = newValue }
    }

    @ToolbarContentBuilder
    private func lifecycleToolbar(_ domain: DomainSummary) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if domain.isActive {
                if domain.state.isPaused {
                    button("Resume", "play.fill", .resume, key: .return,
                           help: "Resume — continue running the paused VM (⌘↩)")
                } else {
                    button("Pause", "pause.fill", .pause, key: "p", modifiers: [.command, .shift],
                           help: "Pause — freeze the VM in memory (⇧⌘P)")
                }
                driftAwareButton("Shut Down", "power", .shutdown, key: "d", modifiers: [.command, .shift],
                                 help: "Shut Down — graceful ACPI shutdown (⇧⌘D)")
                driftAwareButton("Reboot", "arrow.clockwise", .reboot, key: "r", modifiers: [.command, .shift],
                                 help: "Reboot — graceful guest restart (⇧⌘R)")
                if !domain.state.isPaused {
                    Button { requestLifecycle(.save) } label: {
                        Label("Save", systemImage: "square.and.arrow.down")
                    }
                    .help("Save — hibernate the VM to disk (managed save)")
                }
                Button(role: .destructive) {
                    requestLifecycle(.forceOff)
                } label: { Label("Force Off", systemImage: "bolt.fill") }
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                    .help("Force Off — pull the plug immediately (⇧⌘.)")
                Button { onClone(domain) } label: {
                    Label("Clone", systemImage: "plus.square.on.square")
                }
                .help("Clone — create an independent copy")
                Button(role: .destructive) { onDelete(domain) } label: {
                    Label("Delete", systemImage: "trash")
                }
                .help("Delete — remove the VM and optionally its disks")
            } else {
                Button { performLifecycle(.start) } label: {
                    Label(hasManagedSave ? "Restore" : "Start",
                          systemImage: "play.fill")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .help(hasManagedSave
                      ? "Restore — resume from the saved state on disk (⌘↩)"
                      : "Start — power on the VM (⌘↩)")
                if hasManagedSave {
                    Button { confirmDiscardSave = true } label: {
                        Label("Discard State", systemImage: "trash.slash")
                    }
                    .help("Discard the saved state so the next start boots fresh")
                }
                Button { onClone(domain) } label: {
                    Label("Clone", systemImage: "plus.square.on.square")
                }
                Button(role: .destructive) { onDelete(domain) } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    /// Hidden buttons so shortcuts work even when toolbar items aren't focused.
    @ViewBuilder
    private func lifecycleShortcuts(_ domain: DomainSummary) -> some View {
        Group {
            if domain.isActive {
                if domain.state.isPaused {
                    Button("") { performLifecycle(.resume) }
                        .keyboardShortcut(.return, modifiers: .command).hidden()
                } else {
                    Button("") { performLifecycle(.pause) }
                        .keyboardShortcut("p", modifiers: [.command, .shift]).hidden()
                }
                Button("") { requestLifecycle(.shutdown) }
                    .keyboardShortcut("d", modifiers: [.command, .shift]).hidden()
                Button("") { requestLifecycle(.reboot) }
                    .keyboardShortcut("r", modifiers: [.command, .shift]).hidden()
                Button("") { requestLifecycle(.forceOff) }
                    .keyboardShortcut(".", modifiers: [.command, .shift]).hidden()
            } else {
                Button("") { performLifecycle(.start) }
                    .keyboardShortcut(.return, modifiers: .command).hidden()
            }
        }
    }

    private func button(_ title: String, _ symbol: String, _ action: DomainAction,
                        key: KeyEquivalent, modifiers: EventModifiers = .command,
                        help: String) -> some View {
        Button { requestLifecycle(action) } label: { Label(title, systemImage: symbol) }
            .keyboardShortcut(key, modifiers: modifiers)
            .help(help)
    }

    private func driftAwareButton(_ title: String, _ symbol: String, _ action: DomainAction,
                                  key: KeyEquivalent, modifiers: EventModifiers = .command,
                                  help: String) -> some View {
        button(title, symbol, action, key: key, modifiers: modifiers, help: help)
    }

    private func requestLifecycle(_ action: DomainAction) {
        if action == .forceOff, !session.hasConfigDrift(uuid: uuid) {
            confirmForceOff = true
            return
        }
        if action == .save, !session.hasConfigDrift(uuid: uuid) {
            confirmSave = true
            return
        }
        guard domain?.isActive == true, session.hasConfigDrift(uuid: uuid),
              action == .shutdown || action == .reboot || action == .forceOff || action == .save else {
            if action == .forceOff { confirmForceOff = true }
            else if action == .save { confirmSave = true }
            else { performLifecycle(action) }
            return
        }
        pendingDriftAction = action
        confirmDriftPower = true
    }

    private func driftConfirmTitle(_ action: DomainAction) -> String {
        switch action {
        case .shutdown: return "Shut Down Anyway"
        case .reboot: return "Reboot Anyway"
        case .forceOff: return "Force Off Anyway"
        case .save: return "Save Anyway"
        default: return "Continue"
        }
    }

    private func driftConfirmDestructive(_ action: DomainAction) -> Bool {
        action == .forceOff
    }

    private func subtitle(for domain: DomainSummary) -> String {
        var parts = [domain.state.label]
        if domain.isActive, session.hasConfigDrift(uuid: domain.uuid) {
            parts.append("config drift")
        }
        if !domain.isActive, hasManagedSave {
            parts.append("saved state on disk")
        }
        return parts.joined(separator: " · ")
    }

    private func refreshManagedSave() async {
        hasManagedSave = (try? await session.hasManagedSave(uuid: uuid)) ?? false
    }

    private func discardSave() {
        Task {
            do {
                try await session.removeManagedSave(uuid: uuid)
                await refreshManagedSave()
            } catch {
                lifecycleError = error.localizedDescription
            }
        }
    }

    private func performLifecycle(_ action: DomainAction) {
        pendingDriftAction = nil
        Task {
            do {
                try await session.perform(action, on: uuid)
                if action == .save { await refreshManagedSave() }
            } catch {
                lifecycleError = error.localizedDescription
            }
        }
    }
}