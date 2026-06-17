import AppKit
import RoyalVNCKit

/// Refreshes a live console view after an external resize (detached window, fullscreen).
public func refreshConsoleViewAfterResize(_ view: NSView) {
    if let vnc = view as? VNCCAFramebufferView {
        vnc.refreshDisplayAfterResize()
    } else {
        view.setNeedsDisplay(view.bounds)
    }
}

extension VNCCAFramebufferView {
    /// Re-applies layer scaling when Auto Layout resizes the view (bypasses `frame` setter).
    func refreshDisplayAfterResize() {
        // RoyalVNCKit only updates `contentsGravity` in the `frame` setter; constraint
        // and fullscreen resizes go through `setFrameSize` instead.
        let current = frame
        frame = CGRect(origin: current.origin, size: bounds.size)
    }
}