import CLibvirt

/// Thin helpers that don't need an open connection.
public enum Libvirt {
    /// The version of the libvirt library this app is linked against,
    /// formatted as "major.minor.release".
    public static func libraryVersion() -> String {
        var version: UInt = 0
        guard virGetVersion(&version, nil, nil) == 0 else {
            return "unknown"
        }
        let major = version / 1_000_000
        let minor = (version % 1_000_000) / 1_000
        let release = version % 1_000
        return "\(major).\(minor).\(release)"
    }
}
