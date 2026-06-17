import AppKit

/// Renders the SPICE framebuffer and forwards mouse/keyboard input to the
/// inputs channel. Sized 1:1 with the framebuffer inside a scroll view.
public final class SpiceDisplayView: NSView {
    weak var bridge: SpiceBridge?
    weak var session: SpiceConsoleSession?

    private var fbWidth = 0
    private var fbHeight = 0
    private var buttonMask: Int32 = 0
    private var pressedModifiers: Set<UInt16> = []
    private var trackingAreaRef: NSTrackingArea?

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override func becomeFirstResponder() -> Bool { true }
    // The view fills its pane; the framebuffer is scaled to fit (never drives layout).
    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    func primaryChanged(width: Int, height: Int) {
        fbWidth = width; fbHeight = height
        refreshDisplay()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refreshDisplay()
    }

    public override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        refreshDisplay()
    }

    /// Pushes the current framebuffer into the layer. Safe to call after reparenting
    /// or fullscreen resize (draw-based rendering breaks when the view is layer-backed).
    public func refreshDisplay() {
        wantsLayer = true
        guard let layer else { return }
        layer.backgroundColor = NSColor.black.cgColor
        layer.isOpaque = true
        layer.masksToBounds = true
        if let window {
            layer.contentsScale = window.backingScaleFactor
        }
        guard fbWidth > 0, fbHeight > 0, bounds.width > 0, bounds.height > 0 else {
            layer.contents = nil
            return
        }
        let size = bounds.size
        if size.width >= CGFloat(fbWidth), size.height >= CGFloat(fbHeight) {
            layer.contentsGravity = .center
        } else {
            layer.contentsGravity = .resizeAspect
        }
        layer.contents = bridge?.makeImage()
    }

    /// Aspect-fit rect for the framebuffer within the current bounds (letterboxed).
    private var imageRect: CGRect {
        guard fbWidth > 0, fbHeight > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / CGFloat(fbWidth), bounds.height / CGFloat(fbHeight))
        let w = CGFloat(fbWidth) * scale, h = CGFloat(fbHeight) * scale
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    // MARK: - Mouse

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    private func framebufferPoint(_ event: NSEvent) -> (Int, Int) {
        let p = convert(event.locationInWindow, from: nil)
        let rect = imageRect
        guard rect.width > 0, rect.height > 0 else { return (0, 0) }
        let fx = (p.x - rect.minX) / rect.width * CGFloat(fbWidth)
        let fy = (p.y - rect.minY) / rect.height * CGFloat(fbHeight)
        let x = min(max(0, Int(fx)), max(0, fbWidth - 1))
        let y = min(max(0, Int(fy)), max(0, fbHeight - 1))
        return (x, y)
    }

    private func sendMotion(_ event: NSEvent) {
        let (x, y) = framebufferPoint(event)
        session?.sendMotion(x: x, y: y, buttonMask: buttonMask)
    }

    public override func mouseMoved(with event: NSEvent)      { sendMotion(event) }
    public override func mouseDragged(with event: NSEvent)    { sendMotion(event) }
    public override func rightMouseDragged(with event: NSEvent) { sendMotion(event) }
    public override func otherMouseDragged(with event: NSEvent) { sendMotion(event) }

    public override func mouseDown(with event: NSEvent)  { pressButton(1, mask: 1, event: event) }
    public override func mouseUp(with event: NSEvent)    { releaseButton(1, mask: 1, event: event) }
    public override func rightMouseDown(with event: NSEvent) { pressButton(3, mask: 4, event: event) }
    public override func rightMouseUp(with event: NSEvent)   { releaseButton(3, mask: 4, event: event) }
    public override func otherMouseDown(with event: NSEvent) { pressButton(2, mask: 2, event: event) }
    public override func otherMouseUp(with event: NSEvent)   { releaseButton(2, mask: 2, event: event) }

    private func pressButton(_ button: Int32, mask: Int32, event: NSEvent) {
        window?.makeFirstResponder(self)
        sendMotion(event)
        buttonMask |= mask
        session?.sendButton(button, mask: buttonMask, down: true)
    }

    private func releaseButton(_ button: Int32, mask: Int32, event: NSEvent) {
        buttonMask &= ~mask
        session?.sendButton(button, mask: buttonMask, down: false)
    }

    public override func scrollWheel(with event: NSEvent) {
        if event.scrollingDeltaY == 0 { return }
        session?.sendWheel(up: event.scrollingDeltaY > 0, mask: buttonMask)
    }

    // MARK: - Keyboard

    public override func keyDown(with event: NSEvent) {
        if let sc = SpiceKeymap.scancode(forMacKeyCode: event.keyCode) {
            session?.sendKey(scancode: sc, down: true)
        }
    }

    public override func keyUp(with event: NSEvent) {
        if let sc = SpiceKeymap.scancode(forMacKeyCode: event.keyCode) {
            session?.sendKey(scancode: sc, down: false)
        }
    }

    public override func flagsChanged(with event: NSEvent) {
        let kc = event.keyCode
        guard let sc = SpiceKeymap.scancode(forMacKeyCode: kc) else { return }

        // Caps Lock is a toggle on macOS (one event per physical tap); emulate a
        // tap so the guest toggles its own caps state.
        if kc == 0x39 {
            session?.sendKey(scancode: sc, down: true)
            session?.sendKey(scancode: sc, down: false)
            return
        }
        guard SpiceKeymap.modifierKeyCodes.contains(kc) else { return }

        // Toggle press/release per keycode — robust regardless of which flag bits
        // the event carries.
        if pressedModifiers.remove(kc) != nil {
            session?.sendKey(scancode: sc, down: false)
        } else {
            pressedModifiers.insert(kc)
            session?.sendKey(scancode: sc, down: true)
        }
    }

    /// Releases every modifier we believe is held. Called when the console loses
    /// keyboard focus so a modifier can't get "stuck down" in the guest (e.g.
    /// holding Shift, then Cmd-Tabbing away — the key-up never reaches us).
    private func releaseHeldModifiers() {
        for kc in pressedModifiers {
            if let sc = SpiceKeymap.scancode(forMacKeyCode: kc) {
                session?.sendKey(scancode: sc, down: false)
            }
        }
        pressedModifiers.removeAll()
    }

    public override func resignFirstResponder() -> Bool {
        releaseHeldModifiers()
        return super.resignFirstResponder()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(focusLost),
                name: NSWindow.didResignKeyNotification, object: window)
        }
        DispatchQueue.main.async { [weak self] in self?.refreshDisplay() }
    }

    @objc private func focusLost() { releaseHeldModifiers() }

    deinit { NotificationCenter.default.removeObserver(self) }
}