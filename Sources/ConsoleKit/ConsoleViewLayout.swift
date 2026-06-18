import AppKit
import RoyalVNCKit

/// Refreshes a live console view after an external resize (detached window, fullscreen).
public func refreshConsoleViewAfterResize(_ view: NSView) {
    if let vnc = view as? VNCCAFramebufferView {
        vnc.refreshDisplayAfterResize()
    }
}

extension VNCCAFramebufferView {
    /// Re-applies layer scaling when Auto Layout resizes the view (bypasses `frame` setter).
    func refreshDisplayAfterResize() {
        guard settings.isScalingEnabled, let layer else { return }
        layer.frame = bounds
        if let window {
            let scale = window.screen?.backingScaleFactor ?? window.backingScaleFactor
            layer.contentsScale = scale
        }
        let size = bounds.size
        let fullscreen = window?.styleMask.contains(.fullScreen) ?? false
        if fullscreen {
            // Fill the screen (aspect-preserved) rather than a small centered image.
            layer.contentsGravity = .resizeAspect
        } else if size.width >= framebufferSize.width, size.height >= framebufferSize.height {
            layer.contentsGravity = .center
        } else {
            layer.contentsGravity = .resizeAspect
        }
        // RoyalVNCKit only updates gravity in the `frame` setter.
        let current = frame
        frame = CGRect(origin: current.origin, size: size)
    }
}