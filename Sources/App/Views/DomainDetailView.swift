import SwiftUI
import LibvirtKit
import ConsoleKit
import SpiceKit

struct DomainDetailView: View {
    @ObservedObject var session: ConnectionSession
    let uuid: String
    var openConsoleOnce: Binding<Bool> = .constant(false)
    /// Open the Delete / Clone sheets (presented by ContentView).
    var onDelete: (DomainSummary) -> Void = { _ in }
    var onClone: (DomainSummary) -> Void = { _ in }

    @EnvironmentObject private var appState: AppState
    @State private var confirmForceOff = false
    @State private var lifecycleError: String?
    // This view is recreated per VM (.id in ContentView), so the selection is
    // restored from a per-VM runtime map in AppState: each VM remembers which
    // tab it was on for the lifetime of the app.
    @State private var tab = 0

    // One console session per VM, owned here so it survives switching between
    // detail tabs (Overview/Settings/XML/Console). Only torn down when this view
    // goes away — i.e. when a different VM is selected — so normal use keeps a
    // single persistent connection instead of reconnecting on every tab switch.
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
                .navigationSubtitle(domain.state.label)
                .toolbar { lifecycleToolbar(domain) }
                .toolbarBackground(.visible, for: .windowToolbar)
                .confirmationDialog("Force off \(domain.name)? Unsaved data may be lost.",
                                    isPresented: $confirmForceOff, titleVisibility: .visible) {
                    Button("Force Off", role: .destructive) { act(.forceOff) }
                }
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
                tab = appState.detailTabs[tabKey] ?? 0
            }
        }
        .onChange(of: tab) { _, newValue in appState.detailTabs[tabKey] = newValue }
    }

    @ToolbarContentBuilder
    private func lifecycleToolbar(_ domain: DomainSummary) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if domain.isActive {
                if domain.state.isPaused {
                    button("Resume", "play.fill", .resume,
                           help: "Resume — continue running the paused VM")
                } else {
                    button("Pause", "pause.fill", .pause,
                           help: "Pause — freeze the VM in memory (no shutdown)")
                }
                button("Shut Down", "power", .shutdown,
                       help: "Shut Down — ask the guest OS to power off gracefully (ACPI)")
                button("Reboot", "arrow.clockwise", .reboot,
                       help: "Reboot — ask the guest OS to restart gracefully")
                Button(role: .destructive) {
                    confirmForceOff = true
                } label: { Label("Force Off", systemImage: "bolt.fill") }
                    .help("Force Off — pull the plug immediately (unsaved data is lost)")
                Button {
                    onClone(domain)
                } label: { Label("Clone", systemImage: "plus.square.on.square") }
                    .help("Clone — create an independent copy (the dialog offers to shut the VM down)")
                Button(role: .destructive) {
                    onDelete(domain)
                } label: { Label("Delete", systemImage: "trash") }
                    .help("Delete — force off, remove the VM, and optionally its disks")
            } else {
                button("Start", "play.fill", .start,
                       help: "Start — power on the VM")
                Button {
                    onClone(domain)
                } label: { Label("Clone", systemImage: "plus.square.on.square") }
                    .help("Clone — create an independent copy of this VM")
                Button(role: .destructive) {
                    onDelete(domain)
                } label: { Label("Delete", systemImage: "trash") }
                    .help("Delete — remove the VM and optionally its disks")
            }
        }
    }

    private func button(_ title: String, _ symbol: String, _ action: DomainAction,
                        help: String) -> some View {
        Button { act(action) } label: { Label(title, systemImage: symbol) }
            .help(help)
    }

    private func act(_ action: DomainAction) {
        Task {
            do { try await session.perform(action, on: uuid) }
            catch { lifecycleError = error.localizedDescription }
        }
    }
}
