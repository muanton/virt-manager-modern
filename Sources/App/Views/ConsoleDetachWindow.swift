import AppKit
import SwiftUI
import ConsoleKit
import SpiceKit

/// Reparents a console `NSView` into a standalone window (detach / reattach).
@MainActor
final class ConsoleDetachController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var isDetached = false

    private var window: NSWindow?
    private weak var consoleView: NSView?
    private weak var host: ConsoleDetachHostView?
    private weak var placeholder: NSView?
    private var constraints: [NSLayoutConstraint] = []
    private var extraRefresh: (() -> Void)?

    func detach(view: NSView, title: String, refresh: (() -> Void)? = nil) {
        guard window == nil, let parent = view.superview else { return }
        consoleView = view
        extraRefresh = refresh

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
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        w.title = title
        w.delegate = self
        w.isReleasedWhenClosed = false
        w.contentMinSize = NSSize(width: 320, height: 240)
        w.backgroundColor = .black
        w.collectionBehavior = [.fullScreenPrimary, .managed]

        // Keep the window's default content view — replacing it breaks fullscreen/zoom sizing.
        guard let root = w.contentView else { return }
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        root.autoresizesSubviews = true

        let box = ConsoleDetachHostView(frame: root.bounds)
        box.autoresizingMask = [.width, .height]
        box.consoleView = view
        box.onLayout = { [weak self] in self?.refreshConsoleView() }
        root.addSubview(box)
        host = box

        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = [.width, .height]
        view.frame = box.bounds
        box.addSubview(view)

        window = w
        isDetached = true
        w.center()
        w.makeKeyAndOrderFront(nil)
        scheduleRefreshes()
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    }

    func reattach() {
        guard let view = consoleView, let ph = placeholder, let parent = ph.superview else {
            closeWindow()
            return
        }
        view.removeFromSuperview()
        host?.removeFromSuperview()
        ph.removeFromSuperview()
        placeholder = nil
        host = nil
        extraRefresh = nil

        parent.addSubview(view)
        NSLayoutConstraint.activate(constraints)
        constraints = []
        consoleView = nil
        closeWindow()
        DispatchQueue.main.async {
            if let spice = view as? SpiceDisplayView {
                spice.refreshDisplay()
            }
            refreshConsoleViewAfterResize(view)
            view.window?.makeFirstResponder(view)
        }
    }

    func toggleFullscreen() {
        window?.toggleFullScreen(nil)
        scheduleRefreshes()
    }

    func windowWillClose(_ notification: Notification) {
        reattach()
    }

    func windowDidResize(_ notification: Notification) {
        scheduleRefreshes()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        scheduleRefreshes()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        scheduleRefreshes()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        scheduleRefreshes()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        scheduleRefreshes()
    }

    private func layoutConsoleView() {
        guard let view = consoleView, let box = host, let root = box.superview else { return }
        let target = root.bounds
        if box.frame != target {
            box.frame = target
        }
        if view.frame != box.bounds {
            view.frame = box.bounds
        }
    }

    private func refreshConsoleView() {
        layoutConsoleView()
        extraRefresh?()
        guard let view = consoleView else { return }
        if let spice = view as? SpiceDisplayView {
            spice.refreshDisplay()
        } else {
            refreshConsoleViewAfterResize(view)
        }
    }

    /// Zoom and fullscreen animations settle asynchronously; refresh repeatedly to catch final bounds.
    private func scheduleRefreshes() {
        for delay in [0.0, 0.05, 0.15, 0.35, 0.6, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refreshConsoleView()
            }
        }
    }

    private func closeWindow() {
        window?.delegate = nil
        window?.orderOut(nil)
        window = nil
        isDetached = false
    }
}

/// Hosts the console view inside the window's default content view (not as contentView itself).
private final class ConsoleDetachHostView: NSView {
    weak var consoleView: NSView?
    var onLayout: (() -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        pinConsole()
    }

    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        pinConsole()
    }

    override func layout() {
        super.layout()
        pinConsole()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        pinConsole()
    }

    private func pinConsole() {
        if let consoleView {
            consoleView.frame = bounds
        }
        onLayout?()
    }
}