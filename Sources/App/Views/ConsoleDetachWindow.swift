import AppKit
import SwiftUI

/// Reparents a console `NSView` into a standalone window (detach / reattach).
@MainActor
final class ConsoleDetachController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var isDetached = false

    private var window: NSWindow?
    private weak var consoleView: NSView?
    private weak var placeholder: NSView?
    private var constraints: [NSLayoutConstraint] = []

    func detach(view: NSView, title: String) {
        guard window == nil, let parent = view.superview else { return }
        consoleView = view

        let ph = NSView()
        ph.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(ph)
        NSLayoutConstraint.activate([
            ph.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            ph.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            ph.topAnchor.constraint(equalTo: parent.topAnchor),
            ph.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ])
        placeholder = ph

        constraints = parent.constraints.filter {
            ($0.firstItem as? NSView) === view || ($0.secondItem as? NSView) === view
        }
        NSLayoutConstraint.deactivate(constraints)
        view.removeFromSuperview()

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.title = title
        w.delegate = self
        w.isReleasedWhenClosed = false
        w.contentMinSize = NSSize(width: 320, height: 240)
        w.backgroundColor = .black

        let container = NSView(frame: w.contentView?.bounds ?? .zero)
        container.autoresizingMask = [.width, .height]
        w.contentView = container

        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        window = w
        isDetached = true
        w.center()
        w.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    }

    func reattach() {
        guard let view = consoleView, let ph = placeholder, let parent = ph.superview else {
            closeWindow()
            return
        }
        view.removeFromSuperview()
        ph.removeFromSuperview()
        placeholder = nil

        parent.addSubview(view)
        NSLayoutConstraint.activate(constraints)
        constraints = []
        consoleView = nil
        closeWindow()
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    }

    func toggleFullscreen() {
        window?.toggleFullScreen(nil)
    }

    func windowWillClose(_ notification: Notification) {
        reattach()
    }

    private func closeWindow() {
        window?.delegate = nil
        window?.orderOut(nil)
        window = nil
        isDetached = false
    }
}