import Foundation

/// The graphical console configuration from a domain's `<graphics>` element.
public struct GraphicsInfo: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case vnc, spice, rdp, sdl, egl, dbus
        case unknown
    }

    public var kind: Kind
    public var port: Int?          // -1 / nil when autoport hasn't assigned yet
    public var tlsPort: Int?
    public var autoport: Bool
    public var listen: String?     // listen address, e.g. 127.0.0.1 or 0.0.0.0
    public var password: String?
    public var socketPath: String?

    public init(kind: Kind, port: Int? = nil, tlsPort: Int? = nil, autoport: Bool = false,
                listen: String? = nil, password: String? = nil, socketPath: String? = nil) {
        self.kind = kind
        self.port = port
        self.tlsPort = tlsPort
        self.autoport = autoport
        self.listen = listen
        self.password = password
        self.socketPath = socketPath
    }

    /// True when the console listens only on loopback / a non-public address,
    /// implying remote access needs an SSH tunnel.
    public var listensOnLoopback: Bool {
        guard let listen else { return true }
        return listen == "127.0.0.1" || listen == "localhost" || listen == "::1"
    }
}
