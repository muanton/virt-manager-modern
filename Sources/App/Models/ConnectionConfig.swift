import Foundation

/// A hypervisor preset, mirroring virt-manager's "Hypervisor" dropdown.
enum Hypervisor: String, CaseIterable, Identifiable, Hashable {
    case qemuSystem  = "QEMU/KVM"
    case qemuSession = "QEMU/KVM User Session"
    case xen         = "Xen"
    case lxc         = "LXC (Linux Containers)"
    case bhyve       = "Bhyve"
    case test        = "Test (dummy driver)"

    var id: String { rawValue }

    var driver: String {
        switch self {
        case .qemuSystem, .qemuSession: return "qemu"
        case .xen:   return "xen"
        case .lxc:   return "lxc"
        case .bhyve: return "bhyve"
        case .test:  return "test"
        }
    }

    var path: String {
        switch self {
        case .qemuSession: return "session"
        case .test:        return "default"
        default:           return "system"
        }
    }

    var supportsRemote: Bool { self != .test }
}

/// A transport for remote connections (virt-manager's "Method").
enum Transport: String, CaseIterable, Identifiable, Hashable {
    case ssh     = "ssh"
    case tls     = "tls"
    case tcp     = "tcp"
    case libssh2 = "libssh2"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .ssh:     return "SSH"
        case .tls:     return "TLS (x509)"
        case .tcp:     return "TCP (plain)"
        case .libssh2: return "libssh2"
        }
    }
}

/// A saved libvirt connection target. Builds a libvirt URI from its parts, or
/// uses `customURI` verbatim (e.g. `test:///default`).
struct ConnectionConfig: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var driver: String = "qemu"     // qemu, xen, lxc…
    var transport: String? = "ssh"  // ssh, tls, tcp; nil = local
    var user: String?
    var host: String?
    var port: Int?
    var path: String = "system"     // system | session | default
    var customURI: String?
    var autoconnect: Bool = false

    /// The libvirt connection URI.
    var uri: String {
        if let customURI, !customURI.isEmpty { return customURI }
        var scheme = driver
        if let transport, !transport.isEmpty { scheme += "+\(transport)" }
        var s = "\(scheme)://"
        if let user, !user.isEmpty { s += "\(user)@" }
        if let host, !host.isEmpty { s += host }
        if let port { s += ":\(port)" }
        s += "/\(path)"
        return s
    }

    var isRemote: Bool { (host?.isEmpty == false) }

    /// Host used for SSH tunnelling the console (nil for non-SSH transports).
    var sshHost: String? { (transport == "ssh") ? host : nil }
    var sshUser: String? { user }
    var sshPort: Int? { port }

    /// The built-in `test:///default` connection cannot be removed.
    var isBuiltIn: Bool { customURI == "test:///default" }

    static let testDriver = ConnectionConfig(
        name: "Local test driver",
        driver: "test",
        transport: nil,
        path: "default",
        customURI: "test:///default",
        autoconnect: true)

    // Tolerant decoding so connection files written before a field existed still load.
    enum CodingKeys: String, CodingKey {
        case id, name, driver, transport, user, host, port, path, customURI, autoconnect
    }

    init(id: UUID = UUID(), name: String, driver: String = "qemu",
         transport: String? = "ssh", user: String? = nil, host: String? = nil,
         port: Int? = nil, path: String = "system", customURI: String? = nil,
         autoconnect: Bool = false) {
        self.id = id; self.name = name; self.driver = driver; self.transport = transport
        self.user = user; self.host = host; self.port = port; self.path = path
        self.customURI = customURI; self.autoconnect = autoconnect
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        driver = try c.decodeIfPresent(String.self, forKey: .driver) ?? "qemu"
        transport = try c.decodeIfPresent(String.self, forKey: .transport)
        user = try c.decodeIfPresent(String.self, forKey: .user)
        host = try c.decodeIfPresent(String.self, forKey: .host)
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? "system"
        customURI = try c.decodeIfPresent(String.self, forKey: .customURI)
        autoconnect = try c.decodeIfPresent(Bool.self, forKey: .autoconnect) ?? false
    }
}
