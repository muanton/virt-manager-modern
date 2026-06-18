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
                    Button("Force Off", role: .destructive) { act(.forceOff) }
                }
                .confirmationDialog(
                    "Save \(domain.name) to disk? The VM will shut down and its memory state is stored on the host.",
                    isPresented: $confirmSave, titleVisibility: .visible) {
                    Button("Save") { act(.save) }
                }
                .confirmationDialog(
                    "Discard saved state for \(domain.name)? The next start will boot fresh.",
                    isPresented: $confirmDiscardSave, titleVisibility: .visible) {
                    Button("Discard", role: .destructive) { discardSave() }
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
                button("Shut Down", "power", .shutdown, key: "d", modifiers: [.command, .shift],
                       help: "Shut Down — graceful ACPI shutdown (⇧⌘D)")
                button("Reboot", "arrow.clockwise", .reboot, key: "r", modifiers: [.command, .shift],
                       help: "Reboot — graceful guest restart (⇧⌘R)")
                if !domain.state.isPaused {
                    Button { confirmSave = true } label: {
                        Label("Save", systemImage: "square.and.arrow.down")
                    }
                    .help("Save — hibernate the VM to disk (managed save)")
                }
                Button(role: .destructive) {
                    confirmForceOff = true
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
                Button { act(.start) } label: {
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
                    Button("") { act(.resume) }
                        .keyboardShortcut(.return, modifiers: .command).hidden()
                } else {
                    Button("") { act(.pause) }
                        .keyboardShortcut("p", modifiers: [.command, .shift]).hidden()
                }
                Button("") { act(.shutdown) }
                    .keyboardShortcut("d", modifiers: [.command, .shift]).hidden()
                Button("") { act(.reboot) }
                    .keyboardShortcut("r", modifiers: [.command, .shift]).hidden()
                Button("") { confirmForceOff = true }
                    .keyboardShortcut(".", modifiers: [.command, .shift]).hidden()
            } else {
                Button("") { act(.start) }
                    .keyboardShortcut(.return, modifiers: .command).hidden()
            }
        }
    }

    private func button(_ title: String, _ symbol: String, _ action: DomainAction,
                        key: KeyEquivalent, modifiers: EventModifiers = .command,
                        help: String) -> some View {
        Button { act(action) } label: { Label(title, systemImage: symbol) }
            .keyboardShortcut(key, modifiers: modifiers)
            .help(help)
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

    private func act(_ action: DomainAction) {
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