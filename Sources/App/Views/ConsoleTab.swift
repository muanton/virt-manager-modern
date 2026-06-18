import SwiftUI
import AppKit
import LibvirtKit
import DomainModel
import ConsoleKit
import SpiceKit

struct ConsoleTab: View {
    @EnvironmentObject private var preferences: AppPreferences
    @ObservedObject var session: ConnectionSession
    let domain: DomainSummary
    // Owned by DomainDetailView so the connection persists across tab switches.
    @ObservedObject var vnc: VNCSession
    @ObservedObject var spice: SpiceConsoleSession
    @State private var graphics: GraphicsInfo?
    @State private var hasSerialDevice = false
    @State private var consoleMode = "graphical"   // graphical | serial
    @State private var videoModel: String?
    @State private var loaded = false
    @State private var loadError: String?
    @State private var showQXLBanner = true
    @State private var switching = false
    @State private var switchResult: String?
    @State private var connectedForDomainID: Int32 = -2
    @State private var hasUsbRedirection = false
    @State private var showUsbPicker = false
    @State private var monitorPickerID = ""
    @StateObject private var detach = ConsoleDetachController()

    var body: some View {
        // Everything — banner included — lives inside the GeometryReader, which
        // accepts any proposed size. Nothing here can report a minimum height to
        // the window (the banner's wrapping text once blew the layout up to
        // ~1900pt during the min-size probe, centering the whole split view and
        // pushing the sidebar off-screen).
        GeometryReader { geo in
            VStack(spacing: 0) {
                if showQXLBanner, videoModel == "qxl" { qxlBanner }
                if domain.state.isActive, graphics != nil, hasSerialDevice {
                    Picker("", selection: $consoleMode) {
                        Text("Display").tag("graphical")
                        Text("Serial").tag("serial")
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                    .padding(.vertical, 6)
                }
                ZStack { content }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .background(consoleConnected ? Color.black : Color.clear)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .task(id: taskKey) { await prepare() }
        .onDisappear { detach.reattach() }
        .toolbar { consoleToolbar }
        .sheet(isPresented: $showUsbPicker) {
            SpiceUsbPickerSheet(spice: spice, vmHasUsbChannel: hasUsbRedirection)
        }
    }

    @ToolbarContentBuilder
    private var consoleToolbar: some ToolbarContent {
        if consoleConnected, !showSerial {
            ToolbarItemGroup(placement: .automatic) {
                if spice.status == .connected, spice.monitors.count > 1 {
                    Picker("Monitor", selection: $monitorPickerID) {
                        ForEach(Array(spice.monitors.enumerated()), id: \.element.id) { index, monitor in
                            Text("Monitor \(index + 1) (\(monitor.label))").tag(monitor.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220)
                    .onChange(of: monitorPickerID) { _, newValue in
                        guard let monitor = spice.monitors.first(where: { $0.id == newValue }) else { return }
                        spice.selectMonitor(channelId: monitor.channelId, monitorId: monitor.monitorId)
                    }
                    .onChange(of: spice.selectedMonitorID) { _, newValue in
                        if let newValue, newValue != monitorPickerID {
                            monitorPickerID = newValue
                        }
                    }
                    .onAppear {
                        if let selected = spice.selectedMonitorID {
                            monitorPickerID = selected
                        }
                    }
                }
                if spice.status == .connected, preferences.spiceUsbEnabled {
                    Button { showUsbPicker = true } label: {
                        Label("USB Devices", systemImage: "cable.connector")
                    }
                    .help("Redirect USB devices into the guest")
                }
                if detach.isDetached {
                    Button { detach.reattach() } label: {
                        Label("Reattach", systemImage: "arrow.down.right.and.arrow.up.left")
                    }
                    .help("Move the console back into this tab")
                } else if spice.status == .connected || vnc.status == .connected {
                    Button { detachConsole() } label: {
                        Label("Detach", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    .help("Open the console in a separate window")
                }
                if detach.isDetached {
                    Button { detach.toggleFullscreen() } label: {
                        Label("Fullscreen", systemImage: "arrow.up.left.and.bottomright.rectangle")
                    }
                    .help("Toggle fullscreen on the detached window")
                }
            }
        }
    }

    private func detachConsole() {
        let view = spice.displayView ?? vnc.framebufferView
        guard let view else { return }
        detach.detach(view: view, title: "\(domain.name) — Console") { [vnc, spice] in
            if view === vnc.framebufferView {
                vnc.refreshDisplay()
            } else if view === spice.displayView, let spiceView = view as? SpiceDisplayView {
                spiceView.refreshDisplay()
            }
        }
    }

    // MARK: - QXL warning

    private var qxlBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("This VM uses the QXL video device").font(.callout).bold()
                Text("QXL can freeze the console under heavy output on Ubuntu 5.15+ kernels. "
                   + "Switching to virtio-gpu fixes it (takes effect after the VM is fully "
                   + "powered off and started).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let switchResult {
                    Text(switchResult).font(.caption).foregroundStyle(.green)
                }
            }
            Spacer()
            Button(switching ? "Switching…" : "Switch to virtio-gpu") {
                Task { await switchToVirtio() }
            }
            .disabled(switching)
            Button { showQXLBanner = false } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
    }

    private func switchToVirtio() async {
        switching = true
        defer { switching = false }
        do {
            let xml = try await session.domainXML(uuid: domain.uuid)
            let cfg = try DomainConfig(xml: xml)
            guard let newXML = cfg.xmlSwitchingVideoToVirtio() else {
                switchResult = "Couldn't read the VM's video configuration."
                return
            }
            _ = try await session.defineXML(newXML)
            videoModel = "virtio"
            switchResult = "Switched to virtio-gpu. Power-cycle the VM (Shut Down → Start) to apply."
        } catch {
            switchResult = error.localizedDescription
        }
    }

    // Drive the view from the (persistent) session status rather than the
    // transient @State, which resets when the tab is re-shown.
    private var spiceActive: Bool {
        switch spice.status { case .idle, .disconnected: return false; default: return true }
    }
    private var vncActive: Bool {
        switch vnc.status { case .idle, .disconnected: return false; default: return true }
    }
    private var consoleActive: Bool { spiceActive || vncActive }

    @ViewBuilder private var content: some View {
        if !domain.state.isActive {
            ContentUnavailableView("VM is not running", systemImage: "display",
                description: Text("Start the VM to open its console."))
        } else if showSerial {
            SerialConsoleView(session: session, uuid: domain.uuid)
                .id(domain.uuid)
        } else if detach.isDetached {
            ContentUnavailableView("Console Detached", systemImage: "rectangle.on.rectangle",
                description: Text("The display is open in a separate window. Click Reattach to bring it back here."))
        } else if spiceActive {
            spiceContent
        } else if vncActive {
            vncContent
        } else if loaded, let g = graphics, g.kind != .vnc, g.kind != .spice {
            ContentUnavailableView("Unsupported console (\(g.kind.rawValue.uppercased()))",
                systemImage: "display",
                description: Text("Only VNC and SPICE consoles are supported."))
        } else if loaded, graphics == nil {
            ContentUnavailableView("No console", systemImage: "display.trianglebadge.exclamationmark",
                description: Text(loadError ?? "This VM has no graphics or serial console device."))
        } else {
            overlay("Preparing console…")
        }
    }

    // MARK: - VNC

    @ViewBuilder private var vncContent: some View {
        switch vnc.status {
        case .connected:
            if let view = vnc.framebufferView { ConsoleNSView(nsView: view) }
        case .tunneling: overlay("Opening SSH tunnel…")
        case .connecting: overlay("Connecting…")
        case .failed(let m): failure(m)
        case .idle, .disconnected: overlay("Starting…")
        }
    }

    // MARK: - SPICE

    @ViewBuilder private var spiceContent: some View {
        switch spice.status {
        case .connected:
            if let view = spice.displayView { ConsoleNSView(nsView: view) }
        case .tunneling: overlay("Opening SSH tunnel…")
        case .connecting: overlay("Negotiating SPICE…")
        case .failed(let m): failure(m)
        case .idle, .disconnected: overlay("Starting…")
        }
    }

    // MARK: - Shared chrome

    private var consoleConnected: Bool {
        vnc.status == .connected || spice.status == .connected || showSerial
    }

    /// Serial is shown for headless VMs automatically, or when the user picks
    /// it on a VM that has both a display and a serial device.
    private var showSerial: Bool {
        hasSerialDevice && (graphics == nil || consoleMode == "serial")
    }

    /// Includes domainID so a guest reboot (new runtime id) forces a fresh console.
    private var taskKey: String {
        "\(domain.uuid)-\(domain.state.rawValue)-\(domain.domainID)"
    }

    private func overlay(_ text: String) -> some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text(text).foregroundStyle(.secondary)
        }
    }

    private func failure(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle).foregroundStyle(.orange)
            Text("Console connection failed").font(.headline)
            Text(msg).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Retry") { Task { await prepare(force: true) } }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    // MARK: - Setup

    private func prepare(force: Bool = false) async {
        guard domain.state.isActive else {
            vnc.stop(); spice.stop()
            connectedForDomainID = -2
            return
        }

        // Always refresh graphics + video model (cheap) so the QXL banner is
        // shown reliably even when returning to an already-connected console.
        let xml: String
        do {
            xml = try await session.domainXML(uuid: domain.uuid)
        } catch {
            loadError = error.localizedDescription; loaded = true; return
        }
        let cfg = try? DomainConfig(xml: xml)
        let g = cfg?.graphics
        graphics = g
        videoModel = cfg?.videoModel
        hasUsbRedirection = cfg?.hasUsbRedirection ?? false
        hasSerialDevice = cfg?.deviceList().contains {
            $0.kind == .serial || $0.kind == .console
        } ?? false
        loaded = true
        if showSerial { return }   // serial path needs no tunnel/VNC/SPICE

        let needsReconnect = force || connectedForDomainID != domain.domainID
        if !needsReconnect, consoleActive { return }

        if detach.isDetached { detach.reattach() }
        vnc.stop(); spice.stop()
        connectedForDomainID = domain.domainID

        guard let g, let port = g.port, port > 0 else { return }
        VMMLog.console.info("Opening \(g.kind.rawValue, privacy: .public) console for \(self.domain.name, privacy: .public)")
        let listen = g.listen ?? "127.0.0.1"
        let remoteHost = (listen == "0.0.0.0" || listen == "::") ? "127.0.0.1" : listen
        let target = ConsoleTarget(
            sshHost: session.config.sshHost,
            sshUser: session.config.sshUser,
            sshPort: session.config.sshPort,
            remoteVNCHost: remoteHost,
            vncPort: port,
            password: g.password)

        switch g.kind {
        case .vnc:
            await vnc.start(target, clipboardEnabled: preferences.vncClipboardEnabled)
        case .spice:
            await spice.start(target,
                              clipboardEnabled: preferences.spiceClipboardEnabled,
                              audioEnabled: preferences.spiceAudioEnabled,
                              usbEnabled: preferences.spiceUsbEnabled)
        default:     break
        }
    }
}

/// Hosts a console NSView pinned to fill a container, so the (scaled-to-fit)
/// display never drives SwiftUI layout. The view scales the framebuffer itself.
private struct ConsoleNSView: NSViewRepresentable {
    let nsView: NSView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        pin(nsView, in: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if nsView.superview !== container {
            // The console view may have been reparented into a standalone window
            // (Detach). Don't yank it back into this container — doing so during
            // the detach re-render orphans the view (it ends up in no window),
            // leaving the detached console black. Only adopt the view when it has
            // no other home.
            if let viewWindow = nsView.window, viewWindow !== container.window { return }
            container.subviews.forEach { $0.removeFromSuperview() }
            pin(nsView, in: container)
            // Grab keyboard focus once, when first attached — not on every update
            // (which would fight the sidebar/table for first responder).
            DispatchQueue.main.async { nsView.window?.makeFirstResponder(nsView) }
        }
    }

    private func pin(_ view: NSView, in container: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    /// Fill the proposed space; never report the framebuffer's (huge) size.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView,
                      context: Context) -> CGSize? {
        func dim(_ v: CGFloat?, _ fallback: CGFloat) -> CGFloat {
            guard let v, v.isFinite, v > 0 else { return fallback }
            return v
        }
        return CGSize(width: dim(proposal.width, 320), height: dim(proposal.height, 240))
    }
}
