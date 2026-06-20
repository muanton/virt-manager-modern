import AppKit

/// Small conveniences built on top of an established port forward: copy the
/// local address, open it in a browser, or SSH to the guest (via ProxyJump
/// through the libvirt host, so the guest needs no managed tunnel).
enum QuickConnect {
    static func copyLocalAddress(localPort: Int) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("localhost:\(localPort)", forType: .string)
    }

    static func openInBrowser(localPort: Int) {
        guard let url = URL(string: "http://127.0.0.1:\(localPort)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Builds `ssh -J [user@]host[:port] guestUser@guestIP` — the jump host is the
    /// libvirt server, which can route to the (often private) guest IP.
    static func sshCommand(sshHost: String, sshUser: String?, sshPort: Int?,
                           guestUser: String, guestIP: String) -> String {
        var jump = ""
        if let sshUser, !sshUser.isEmpty { jump += "\(sshUser)@" }
        jump += sshHost
        if let sshPort { jump += ":\(sshPort)" }
        return "ssh -J \(jump) \(guestUser)@\(guestIP)"
    }

    static func openSSH(sshHost: String, sshUser: String?, sshPort: Int?,
                        guestUser: String, guestIP: String) {
        let cmd = sshCommand(sshHost: sshHost, sshUser: sshUser, sshPort: sshPort,
                             guestUser: guestUser, guestIP: guestIP)
        runInTerminal(cmd)
    }

    /// Opens Terminal.app and runs `command` in a new shell via AppleScript.
    private static func runInTerminal(_ command: String) {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        try? proc.run()
    }
}
