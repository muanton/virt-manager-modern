import Foundation
import AppKit
import ConsoleKit
import SpiceShim

/// One guest display surface reported by the SPICE server.
public struct SpiceMonitor: Identifiable, Equatable, Sendable {
    public let channelId: Int
    public let monitorId: Int
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public var id: String { "\(channelId)-\(monitorId)" }

    public var label: String {
        if width > 0, height > 0 {
            return "\(width)×\(height)"
        }
        return "Display"
    }

    init(_ info: VMMMonitorInfo) {
        channelId = Int(info.channel_id)
        monitorId = Int(info.monitor_id)
        x = Int(info.x)
        y = Int(info.y)
        width = Int(info.width)
        height = Int(info.height)
    }
}

/// A host USB device that can be redirected into the SPICE guest.
public struct SpiceUsbDevice: Identifiable, Equatable, Sendable {
    public let id: UInt32
    public let description: String
    public let connected: Bool
    public let canRedirect: Bool
    public let blockReason: String?

    init(_ info: VMMUsbDeviceInfo) {
        id = info.id
        description = Self.cString(info.description)
        connected = info.connected != 0
        canRedirect = info.can_redirect != 0
        let reason = Self.cString(info.block_reason)
        blockReason = reason.isEmpty ? nil : reason
    }

    private static func cString<T>(_ field: T) -> String {
        withUnsafePointer(to: field) { ptr in
            String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
        }
    }
}

/// Drives a SPICE console: opens the SSH tunnel (if needed), runs the spice-gtk
/// session on its own GLib thread, and publishes a live display `NSView`.
/// Mirrors `VNCSession` so the UI can treat the two consoles uniformly.
@MainActor
public final class SpiceConsoleSession: ObservableObject {
    public enum Status: Equatable {
        case idle, tunneling, connecting, connected, disconnected
        case failed(String)
    }

    @Published public private(set) var status: Status = .idle
    @Published public private(set) var displayView: NSView?
    @Published public private(set) var monitors: [SpiceMonitor] = []
    @Published public private(set) var selectedMonitorID: String?
    @Published public private(set) var usbDevices: [SpiceUsbDevice] = []
    @Published public var usbMessage: String?

    private var handle: OpaquePointer?            // VMMSpiceSession*
    private let bridge = SpiceBridge()
    private let clipboard = SpiceClipboard()
    private var tunnel: SSHTunnel?

    public init() {}

    public func start(_ target: ConsoleTarget,
                      clipboardEnabled: Bool = true,
                      audioEnabled: Bool = true,
                      usbEnabled: Bool = true) async {
        guard canStart else { return }
        status = .tunneling

        let host: String
        let port: Int
        do {
            if let sshHost = target.sshHost {
                let t = try SSHTunnel(sshHost: sshHost, sshUser: target.sshUser,
                                      sshPort: target.sshPort,
                                      remoteHost: target.remoteVNCHost, remotePort: target.vncPort)
                try t.start()
                try await t.waitUntilReady(timeout: 15)
                tunnel = t
                host = "127.0.0.1"; port = t.localPort
            } else {
                host = target.remoteVNCHost; port = target.vncPort
            }
        } catch {
            status = .failed(error.localizedDescription)
            return
        }

        status = .connecting
        let view = SpiceDisplayView()
        view.bridge = bridge
        view.session = self
        bridge.view = view
        bridge.session = self
        bridge.clipboard = clipboard
        displayView = view

        var cb = VMMSpiceCallbacks()
        cb.ctx = Unmanaged.passUnretained(bridge).toOpaque()
        cb.primary_create = spicePrimaryCreate
        cb.primary_destroy = spicePrimaryDestroy
        cb.invalidate = spiceInvalidate
        cb.state = spiceState
        cb.clipboard_guest_grab = spiceClipboardGrab
        cb.clipboard_guest_request = spiceClipboardRequest
        cb.clipboard_guest_release = spiceClipboardRelease
        cb.clipboard_guest_data = spiceClipboardData
        cb.usb_devices_changed = spiceUsbDevicesChanged
        cb.usb_redirect_result = spiceUsbRedirectResult
        cb.monitors_changed = spiceMonitorsChanged

        handle = vmm_spice_session_create(host, Int32(port), target.password, cb)
        vmm_spice_audio_enable(handle, audioEnabled ? 1 : 0)
        vmm_spice_usb_enable(handle, usbEnabled ? 1 : 0)
        vmm_spice_session_start(handle)
        clipboard.start(session: self, handle: handle, enabled: clipboardEnabled)
        refreshMonitors()
        refreshUsbDevices()
    }

    public func stop() {
        clipboard.stop()
        if let handle { vmm_spice_session_stop(handle) }
        handle = nil
        bridge.cleanup()
        tunnel?.stop(); tunnel = nil
        displayView = nil
        monitors = []
        selectedMonitorID = nil
        usbDevices = []
        usbMessage = nil
        status = .idle
    }

    deinit {
        if let handle { vmm_spice_session_stop(handle) }
        tunnel?.stop()
    }

    // MARK: - Called back from the bridge

    func markConnected() { status = .connected }

    func handleState(connected: Bool, error: String?) {
        if let error {
            status = .failed(error)
        } else if !connected, status == .connected {
            status = .disconnected
        }
    }

    /// Input forwarding to the SPICE inputs channel (used by the display view).
    func sendKey(scancode: UInt32, down: Bool) {
        guard let handle else { return }
        vmm_spice_key(handle, scancode, down ? 1 : 0)
    }
    func sendMotion(x: Int, y: Int, buttonMask: Int32) {
        guard let handle else { return }
        vmm_spice_mouse_motion_abs(handle, Int32(x), Int32(y), buttonMask)
    }
    func sendButton(_ button: Int32, mask: Int32, down: Bool) {
        guard let handle else { return }
        vmm_spice_mouse_button(handle, button, mask, down ? 1 : 0)
    }
    func sendWheel(up: Bool, mask: Int32) {
        guard let handle else { return }
        vmm_spice_mouse_wheel(handle, up ? 1 : 0, mask)
    }

    // MARK: - Multi-monitor

    public func refreshMonitors() {
        guard let handle else {
            monitors = []
            selectedMonitorID = nil
            return
        }
        let sessionHandle = handle
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var buf = [VMMMonitorInfo](repeating: VMMMonitorInfo(), count: 16)
            let n = buf.withUnsafeMutableBufferPointer { ptr in
                vmm_spice_list_monitors(sessionHandle, ptr.baseAddress, Int32(ptr.count))
            }
            let list = (0..<Int(n)).map { SpiceMonitor(buf[$0]) }
            await MainActor.run {
                self.monitors = list
                if let selected = self.selectedMonitorID,
                   list.contains(where: { $0.id == selected }) {
                    return
                }
                self.selectedMonitorID = list.first?.id
            }
        }
    }

    public func selectMonitor(channelId: Int, monitorId: Int) {
        guard let handle else { return }
        let key = "\(channelId)-\(monitorId)"
        selectedMonitorID = key
        vmm_spice_select_monitor(handle, Int32(channelId), Int32(monitorId))
    }

    func handleMonitorsChanged() { refreshMonitors() }

    // MARK: - USB redirection

    public func refreshUsbDevices() {
        guard let handle else {
            usbDevices = []
            return
        }
        let sessionHandle = handle
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var buf = [VMMUsbDeviceInfo](repeating: VMMUsbDeviceInfo(), count: 64)
            let n = buf.withUnsafeMutableBufferPointer { ptr in
                vmm_spice_usb_list_devices(sessionHandle, ptr.baseAddress, Int32(ptr.count))
            }
            let devices = (0..<Int(n)).map { SpiceUsbDevice(buf[$0]) }
            await MainActor.run { self.usbDevices = devices }
        }
    }

    public func connectUsbDevice(id: UInt32) {
        guard let handle else { return }
        vmm_spice_usb_connect(handle, id)
    }

    public func disconnectUsbDevice(id: UInt32) {
        guard let handle else { return }
        vmm_spice_usb_disconnect(handle, id)
    }

    func handleUsbDevicesChanged() { refreshUsbDevices() }

    func handleUsbRedirectResult(deviceID: UInt32, ok: Bool, error: String?) {
        if let error, !ok { usbMessage = error } else { usbMessage = nil }
        refreshUsbDevices()
    }

    private var canStart: Bool {
        switch status {
        case .idle, .disconnected, .failed: return true
        default: return false
        }
    }
}
