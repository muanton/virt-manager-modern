import Foundation
import CoreGraphics
import SpiceShim

/// Holds the framebuffer and bridges the C shim's (GLib-thread) callbacks to the
/// UI. Buffer access is locked; everything touching AppKit hops to main.
final class SpiceBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: UnsafeMutablePointer<UInt8>?
    private var source: UnsafePointer<UInt8>?
    private(set) var width = 0
    private(set) var height = 0
    private var stride = 0
    private var redrawPending = false

    weak var view: SpiceDisplayView?
    weak var session: SpiceConsoleSession?
    weak var clipboard: SpiceClipboard?

    // MARK: - Called from the SPICE thread

    func primaryCreate(width: Int, height: Int, stride: Int, data: UnsafePointer<UInt8>) {
        lock.lock()
        buffer?.deallocate()
        let size = max(0, stride * height)
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        buf.update(from: data, count: size)
        self.buffer = buf
        self.source = data
        self.width = width; self.height = height; self.stride = stride
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.view?.primaryChanged(width: width, height: height)
            self?.session?.markConnected()
        }
    }

    func invalidate(y: Int, height h: Int) {
        lock.lock()
        // Keep the offscreen buffer current on every invalidate (cheap, dirty
        // rows only)…
        if let buffer, let source, stride > 0, height > 0 {
            let yy = max(0, y)
            let hh = min(height - yy, h)
            if hh > 0 {
                let offset = yy * stride
                buffer.advanced(by: offset)
                    .update(from: source.advanced(by: offset), count: hh * stride)
            }
        }
        // …but coalesce redraws: never have more than one pending on the main
        // thread, so a flood of invalidates (e.g. fast-scrolling text) can't
        // swamp the UI. This caps redraws at the run loop's pace.
        let schedule = !redrawPending
        redrawPending = true
        lock.unlock()

        guard schedule else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.redrawPending = false; self.lock.unlock()
            self.view?.needsDisplay = true
        }
    }

    func primaryDestroy() {
        lock.lock(); source = nil; lock.unlock()
    }

    // MARK: - Called from the main thread

    /// Builds an independent CGImage snapshot of the current framebuffer.
    func makeImage() -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        guard let buffer, width > 0, height > 0, stride > 0 else { return nil }
        let info = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: buffer, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: stride,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)
        else { return nil }
        return ctx.makeImage()
    }

    func cleanup() {
        lock.lock()
        buffer?.deallocate(); buffer = nil; source = nil
        width = 0; height = 0; stride = 0
        lock.unlock()
    }
}

// MARK: - C callback trampolines

func spiceBridge(_ ctx: UnsafeMutableRawPointer?) -> SpiceBridge? {
    guard let ctx else { return nil }
    return Unmanaged<SpiceBridge>.fromOpaque(ctx).takeUnretainedValue()
}

let spicePrimaryCreate: @convention(c) (
    UnsafeMutableRawPointer?, Int32, Int32, Int32, Int32, UnsafePointer<UInt8>?) -> Void = {
    ctx, _, w, h, stride, data in
    guard let bridge = spiceBridge(ctx), let data else { return }
    bridge.primaryCreate(width: Int(w), height: Int(h), stride: Int(stride), data: data)
}

let spicePrimaryDestroy: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ctx in
    spiceBridge(ctx)?.primaryDestroy()
}

let spiceInvalidate: @convention(c) (
    UnsafeMutableRawPointer?, Int32, Int32, Int32, Int32) -> Void = { ctx, _, y, _, h in
    spiceBridge(ctx)?.invalidate(y: Int(y), height: Int(h))
}

let spiceState: @convention(c) (
    UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?) -> Void = { ctx, connected, err in
    guard let bridge = spiceBridge(ctx) else { return }
    let message = err.map { String(cString: $0) }
    DispatchQueue.main.async { [weak session = bridge.session] in
        session?.handleState(connected: connected != 0, error: message)
    }
}

let spiceClipboardGrab: @convention(c) (
    UnsafeMutableRawPointer?, UInt32, UnsafePointer<UInt32>?, Int32) -> Void = { ctx, _, types, n in
    guard let bridge = spiceBridge(ctx), let types, n > 0 else { return }
    let arr = (0..<Int(n)).map { types[$0] }
    DispatchQueue.main.async { bridge.clipboard?.guestGrab(types: arr) }
}

let spiceClipboardRequest: @convention(c) (
    UnsafeMutableRawPointer?, UInt32, UInt32) -> Void = { ctx, _, type in
    DispatchQueue.main.async { spiceBridge(ctx)?.clipboard?.guestRequest(type: type) }
}

let spiceClipboardRelease: @convention(c) (
    UnsafeMutableRawPointer?, UInt32) -> Void = { ctx, _ in
    DispatchQueue.main.async { spiceBridge(ctx)?.clipboard?.guestRelease() }
}

let spiceClipboardData: @convention(c) (
    UnsafeMutableRawPointer?, UInt32, UInt32, UnsafePointer<UInt8>?, Int) -> Void = { ctx, _, type, data, size in
    guard let bridge = spiceBridge(ctx), let data, size > 0 else { return }
    let bytes = Data(bytes: data, count: size)
    DispatchQueue.main.async { bridge.clipboard?.guestData(type: type, data: bytes) }
}
