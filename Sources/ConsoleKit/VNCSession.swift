import Foundation
import AppKit
import RoyalVNCKit

/// Everything needed to reach a VM's VNC console.
public struct ConsoleTarget: Sendable {
    public var sshHost: String?      // nil → connect directly (no tunnel)
    public var sshUser: String?
    public var sshPort: Int?
    public var remoteVNCHost: String // address to reach on the libvirt host (usually 127.0.0.1)
    public var vncPort: Int
    public var password: String?

    public init(sshHost: String?, sshUser: String?, sshPort: Int?,
                remoteVNCHost: String, vncPort: Int, password: String?) {
        self.sshHost = sshHost
        self.sshUser = sshUser
        self.sshPort = sshPort
        self.remoteVNCHost = remoteVNCHost
        self.vncPort = vncPort
        self.password = password
    }
}

/// Drives a single VNC console: opens the SSH tunnel (if needed), runs the
/// RoyalVNCKit connection, and publishes the live framebuffer NSView for SwiftUI.
@MainActor
public final class VNCSession: ObservableObject {
    public enum Status: Equatable {
        case idle
        case tunneling
        case connecting
        case connected
        case disconnected
        case failed(String)
    }

    @Published public private(set) var status: Status = .idle
    /// The live console view, exposed as a plain `NSView` so the app target
    /// doesn't need to import RoyalVNCKit.
    @Published public private(set) var framebufferView: NSView?

    private var fbView: VNCCAFramebufferView?
    private var lastFramebuffer: VNCFramebuffer?
    private var tunnel: SSHTunnel?
    private var connection: VNCConnection?
    private var coordinator: VNCCoordinator?

    public init() {}

    public func start(_ target: ConsoleTarget, clipboardEnabled: Bool = true) async {
        guard canStart else { return }
        status = .tunneling

        let host: String
        let port: Int
        do {
            if let sshHost = target.sshHost {
                let t = try SSHTunnel(sshHost: sshHost, sshUser: target.sshUser, sshPort: target.sshPort,
                                      remoteHost: target.remoteVNCHost, remotePort: target.vncPort)
                try t.start()
                try await t.waitUntilReady(timeout: 15)
                tunnel = t
                host = "127.0.0.1"
                port = t.localPort
            } else {
                host = target.remoteVNCHost
                port = target.vncPort
            }
        } catch {
            status = .failed(error.localizedDescription)
            return
        }

        status = .connecting
        let settings = VNCConnection.Settings(
            isDebugLoggingEnabled: false,
            hostname: host,
            port: UInt16(port),
            isShared: true,
            isScalingEnabled: true,
            useDisplayLink: false,
            inputMode: .forwardKeyboardShortcutsIfNotInUseLocally,
            isClipboardRedirectionEnabled: clipboardEnabled,
            colorDepth: .depth24Bit,
            frameEncodings: VNCFrameEncodingType.defaultFrameEncodings)

        let conn = VNCConnection(settings: settings)
        let coord = VNCCoordinator(session: self, password: target.password)
        conn.delegate = coord
        connection = conn
        coordinator = coord
        conn.connect()
    }

    public func stop() {
        connection?.disconnect()
        connection = nil
        coordinator = nil
        tunnel?.stop()
        tunnel = nil
        fbView = nil
        lastFramebuffer = nil
        framebufferView = nil
        status = .idle
    }

    /// Re-pushes the framebuffer after the view is reparented or resized (detach / fullscreen).
    public func refreshDisplay() {
        guard let fbView, let connection, let fb = lastFramebuffer else { return }
        fbView.connection(connection, didUpdateFramebuffer: fb,
                          x: 0, y: 0, width: fb.size.width, height: fb.size.height)
        refreshConsoleViewAfterResize(fbView)
    }

    deinit {
        connection?.disconnect()
        tunnel?.stop()
    }

    private var canStart: Bool {
        switch status {
        case .idle, .disconnected, .failed: return true
        default: return false
        }
    }

    // MARK: - Coordinator callbacks (always on main)

    func handleState(_ state: VNCConnection.ConnectionState) {
        switch state.status {
        case .connecting:   status = .connecting
        case .connected:    if framebufferView != nil { status = .connected }
        case .disconnecting: break
        case .disconnected:
            if let err = state.error {
                status = .failed(err.localizedDescription)
            } else if status != .disconnected {
                status = .disconnected
            }
        }
    }

    func installFramebuffer(_ connection: VNCConnection, _ framebuffer: VNCFramebuffer) {
        lastFramebuffer = framebuffer
        let view = VNCCAFramebufferView(
            frame: CGRect(origin: .zero, size: framebuffer.size.cgSize),
            framebuffer: framebuffer,
            connection: connection)
        fbView = view
        framebufferView = view
        status = .connected
    }

    func forwardUpdate(_ connection: VNCConnection, _ fb: VNCFramebuffer,
                       _ x: UInt16, _ y: UInt16, _ w: UInt16, _ h: UInt16) {
        lastFramebuffer = fb
        fbView?.connection(connection, didUpdateFramebuffer: fb, x: x, y: y, width: w, height: h)
    }

    func forwardCursor(_ connection: VNCConnection, _ cursor: VNCCursor) {
        fbView?.connection(connection, didUpdateCursor: cursor)
    }
}

/// Non-isolated delegate that bridges RoyalVNCKit's (possibly background-thread)
/// callbacks onto the main actor where the SwiftUI/AppKit state lives.
final class VNCCoordinator: NSObject, VNCConnectionDelegate, @unchecked Sendable {
    private weak var session: VNCSession?
    private let password: String?

    init(session: VNCSession, password: String?) {
        self.session = session
        self.password = password
    }

    func connection(_ connection: VNCConnection,
                    stateDidChange connectionState: VNCConnection.ConnectionState) {
        DispatchQueue.main.async { [weak session] in session?.handleState(connectionState) }
    }

    func connection(_ connection: VNCConnection,
                    credentialFor authenticationType: VNCAuthenticationType,
                    completion: @escaping (VNCCredential?) -> Void) {
        if let password, authenticationType.requiresPassword {
            completion(VNCPasswordCredential(password: password))
        } else {
            completion(nil)
        }
    }

    func connection(_ connection: VNCConnection, didCreateFramebuffer framebuffer: VNCFramebuffer) {
        DispatchQueue.main.async { [weak session] in session?.installFramebuffer(connection, framebuffer) }
    }

    func connection(_ connection: VNCConnection, didResizeFramebuffer framebuffer: VNCFramebuffer) {
        DispatchQueue.main.async { [weak session] in session?.installFramebuffer(connection, framebuffer) }
    }

    func connection(_ connection: VNCConnection, didUpdateFramebuffer framebuffer: VNCFramebuffer,
                    x: UInt16, y: UInt16, width: UInt16, height: UInt16) {
        DispatchQueue.main.async { [weak session] in
            session?.forwardUpdate(connection, framebuffer, x, y, width, height)
        }
    }

    func connection(_ connection: VNCConnection, didUpdateCursor cursor: VNCCursor) {
        DispatchQueue.main.async { [weak session] in session?.forwardCursor(connection, cursor) }
    }
}
