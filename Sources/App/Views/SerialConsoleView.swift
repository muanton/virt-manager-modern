import SwiftUI
import SwiftTerm
import LibvirtKit

/// Text console for a VM's serial/paravirt console device, rendered with
/// SwiftTerm and fed by libvirt's console stream (virDomainOpenConsole).
struct SerialConsoleView: NSViewRepresentable {
    @ObservedObject var session: ConnectionSession
    let uuid: String

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, uuid: uuid)
    }

    func makeNSView(context: Context) -> TerminalView {
        let tv = TerminalView()
        tv.terminalDelegate = context.coordinator
        tv.nativeBackgroundColor = .black
        tv.nativeForegroundColor = NSColor(calibratedWhite: 0.92, alpha: 1)
        context.coordinator.attach(tv)
        return tv
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {}

    static func dismantleNSView(_ nsView: TerminalView, coordinator: Coordinator) {
        coordinator.disconnect()
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        private let session: ConnectionSession
        private let uuid: String
        private weak var terminal: TerminalView?
        private var handle: SerialConsoleHandle?
        private var receivedAny = false

        init(session: ConnectionSession, uuid: String) {
            self.session = session
            self.uuid = uuid
        }

        func attach(_ tv: TerminalView) {
            terminal = tv
            tv.feed(text: "Connecting to console…\r\n")
            Task { await connect() }
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }

        private func connect() async {
            handle = await session.openSerialConsole(
                uuid: uuid,
                onData: { [weak self] data in
                    Task { @MainActor [weak self] in
                        self?.receivedAny = true
                        self?.terminal?.feed(byteArray: ArraySlice([UInt8](data)))
                    }
                },
                onClose: { [weak self] error in
                    Task { @MainActor [weak self] in
                        let msg = error.map { "\r\n[console closed: \($0)]\r\n" }
                                ?? "\r\n[console closed]\r\n"
                        self?.terminal?.feed(text: msg)
                    }
                })
            if handle == nil {
                terminal?.feed(text: "\r\n[\(session.lastError ?? "failed to open console")]\r\n")
            } else {
                terminal?.feed(text: "[connected — keystrokes go to the guest]\r\n")
                // A nudge so the guest reprints its login prompt.
                handle?.send(Data("\r".utf8))
                // A silent port usually means the guest runs no serial getty —
                // say so instead of leaving a black screen.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(4))
                    guard let self, self.handle != nil, !self.receivedAny else { return }
                    self.terminal?.feed(text:
                        "\r\n[no output from the guest — it likely runs no serial getty.\r\n" +
                        " On Ubuntu/Debian: sudo systemctl enable --now serial-getty@ttyS0.service\r\n" +
                        " Kernel messages appear here after a reboot if the guest boots with console=ttyS0.]\r\n")
                }
            }
        }

        nonisolated func disconnect() {
            Task { @MainActor in
                self.handle?.close()
                self.handle = nil
            }
        }

        // MARK: - TerminalViewDelegate

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            handle?.send(Data(data))
        }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func clipboardCopy(source: TerminalView, content: Data) {
            if let s = String(data: content, encoding: .utf8) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(s, forType: .string)
            }
        }
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
