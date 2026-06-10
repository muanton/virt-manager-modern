import Foundation

/// A local SSH port-forward: `ssh -N -L 127.0.0.1:localPort:remoteHost:remotePort`.
/// Used to reach a VNC server that listens only on the libvirt host's loopback.
public final class SSHTunnel {
    public let localPort: Int
    private let process = Process()
    private let sshHost: String
    private let sshUser: String?
    private let sshPort: Int?
    private let remoteHost: String
    private let remotePort: Int

    public init(sshHost: String, sshUser: String?, sshPort: Int?,
                remoteHost: String, remotePort: Int) throws {
        guard let free = Self.freeLocalPort() else {
            throw NSError(domain: "SSHTunnel", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No free local port available"])
        }
        self.localPort = free
        self.sshHost = sshHost
        self.sshUser = sshUser
        self.sshPort = sshPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
    }

    public func start() throws {
        var args = [
            "-N",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=30",
            "-L", "127.0.0.1:\(localPort):\(remoteHost):\(remotePort)",
        ]
        if let sshPort { args += ["-p", "\(sshPort)"] }
        let target = sshUser.map { "\($0)@\(sshHost)" } ?? sshHost
        args.append(target)

        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        try process.run()
    }

    /// Polls the forwarded local port until it accepts a connection, or throws on timeout.
    public func waitUntilReady(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !process.isRunning {
                throw NSError(domain: "SSHTunnel", code: 2, userInfo: [
                    NSLocalizedDescriptionKey:
                        "SSH tunnel exited (status \(process.terminationStatus)). Check SSH keys/host."])
            }
            if Self.canConnect(port: localPort) { return }
            try? await Task.sleep(for: .milliseconds(150))
        }
        throw NSError(domain: "SSHTunnel", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "Timed out establishing SSH tunnel to \(sshHost)"])
    }

    public func stop() {
        if process.isRunning { process.terminate() }
    }

    deinit { stop() }

    // MARK: - POSIX helpers

    /// Reserves an ephemeral port by binding to it, then releases it for `ssh`.
    private static func freeLocalPort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // let the kernel pick
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard got == 0 else { return nil }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    private static func canConnect(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return rc == 0
    }
}
