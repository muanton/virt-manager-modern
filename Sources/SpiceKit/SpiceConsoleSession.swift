import Foundation
import AppKit
import ConsoleKit
import SpiceShim

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

    private var handle: OpaquePointer?            // VMMSpiceSession*
    private let bridge = SpiceBridge()
    private let clipboard = SpiceClipboard()
    private var tunnel: SSHTunnel?

    public init() {}

    public func start(_ target: ConsoleTarget,
                      clipboardEnabled: Bool = true,
                      audioEnabled: Bool = true) async {
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

        handle = vmm_spice_session_create(host, Int32(port), target.password, cb)
        vmm_spice_audio_enable(handle, audioEnabled ? 1 : 0)
        vmm_spice_session_start(handle)
        clipboard.start(session: self, handle: handle, enabled: clipboardEnabled)
    }

    public func stop() {
        clipboard.stop()
        if let handle { vmm_spice_session_stop(handle) }
        handle = nil
        bridge.cleanup()
        tunnel?.stop(); tunnel = nil
        displayView = nil
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

    private var canStart: Bool {
        switch status {
        case .idle, .disconnected, .failed: return true
        default: return false
        }
    }
}
