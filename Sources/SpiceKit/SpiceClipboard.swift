import AppKit
import Foundation
import SpiceShim

/// Bidirectional UTF-8 clipboard sync for SPICE consoles.
@MainActor
final class SpiceClipboard {
    private weak var session: SpiceConsoleSession?
    private var handle: OpaquePointer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var pollTimer: Timer?
    private var guestOwns = false

    func start(session: SpiceConsoleSession, handle: OpaquePointer?) {
        stop()
        self.session = session
        self.handle = handle
        lastChangeCount = NSPasteboard.general.changeCount
        vmm_spice_clipboard_enable(handle, 1)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollPasteboard() }
        }
    }

    func stop() {
        vmm_spice_clipboard_enable(handle, 0)
        pollTimer?.invalidate()
        pollTimer = nil
        handle = nil
        session = nil
        guestOwns = false
    }

    private func pollPasteboard() {
        guard let handle, !guestOwns else { return }
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        guard pb.string(forType: .string)?.isEmpty == false else { return }
        vmm_spice_clipboard_host_grab(handle)
    }

    // MARK: - Called from the C shim (runner thread → main)

    func guestGrab(types: [UInt32]) {
        guestOwns = types.contains(1) // VD_AGENT_CLIPBOARD_UTF8_TEXT
    }

    func guestRequest(type: UInt32) {
        guard type == 1, let handle else { return }
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        guard !text.isEmpty else { return }
        text.utf8.withContiguousStorageIfAvailable { buf in
            vmm_spice_clipboard_host_notify(handle, type, buf.baseAddress, buf.count)
        }
    }

    func guestRelease() {
        guestOwns = false
    }

    func guestData(type: UInt32, data: Data) {
        guard type == 1 else { return }
        guestOwns = false
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        lastChangeCount = NSPasteboard.general.changeCount
    }
}