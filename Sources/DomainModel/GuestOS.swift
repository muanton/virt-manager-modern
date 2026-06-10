import Foundation

/// A guest OS profile — the same role osinfo-db plays for legacy virt-manager:
/// recommended resources plus device/platform tuning for the chosen OS.
/// Curated subset instead of the full libosinfo database (no extra C dep).
public struct GuestOS: Identifiable, Hashable, Sendable {
    public enum Family: String, CaseIterable, Identifiable, Sendable {
        case linux = "Linux"
        case windows = "Windows"
        case bsd = "BSD"
        case generic = "Other / Generic"
        public var id: String { rawValue }
    }

    public let id: String
    public let name: String
    public let family: Family

    // Recommended defaults (pre-fill the wizard, user can override).
    public let memoryMiB: Int
    public let vcpus: Int
    public let diskGiB: Int

    // Device/platform tuning.
    public let diskBus: String        // virtio (has drivers) | sata (works everywhere)
    public let nicModel: String       // virtio | e1000e
    public let videoModel: String     // virtio | qxl (Windows has QXL drivers; Linux
                                      // avoids QXL due to the qxl_fence_wait bug)
    public let clockOffset: String    // utc | localtime (Windows expects RTC localtime)
    public let hyperv: Bool           // Hyper-V enlightenments + hypervclock (Windows)
    public let requiresTPM: Bool      // emulated TPM 2.0 (Windows 11 hard requirement)
    public let requiresUEFI: Bool

    init(_ id: String, _ name: String, _ family: Family,
         mem: Int, cpus: Int, disk: Int,
         hyperv: Bool = false, tpm: Bool = false, uefi: Bool = false) {
        self.id = id; self.name = name; self.family = family
        self.memoryMiB = mem; self.vcpus = cpus; self.diskGiB = disk
        let windows = family == .windows
        self.diskBus = windows ? "sata" : "virtio"
        self.nicModel = windows ? "e1000e" : "virtio"
        self.videoModel = windows ? "qxl" : "virtio"
        self.clockOffset = windows ? "localtime" : "utc"
        self.hyperv = hyperv
        self.requiresTPM = tpm
        self.requiresUEFI = uefi
    }

    /// Recommended resources follow osinfo-db; ordering is newest-first per family.
    public static let catalog: [GuestOS] = [
        // Linux
        .init("linux-generic", "Generic Linux", .linux, mem: 2048, cpus: 2, disk: 20),
        .init("ubuntu24.04", "Ubuntu 24.04 LTS", .linux, mem: 4096, cpus: 2, disk: 25),
        .init("ubuntu22.04", "Ubuntu 22.04 LTS", .linux, mem: 4096, cpus: 2, disk: 25),
        .init("debian13", "Debian 13 (Trixie)", .linux, mem: 2048, cpus: 2, disk: 20),
        .init("debian12", "Debian 12 (Bookworm)", .linux, mem: 2048, cpus: 2, disk: 20),
        .init("fedora42", "Fedora 42", .linux, mem: 4096, cpus: 2, disk: 20),
        .init("rhel9", "RHEL / Alma / Rocky 9", .linux, mem: 4096, cpus: 2, disk: 20),
        .init("opensuse", "openSUSE Leap", .linux, mem: 4096, cpus: 2, disk: 20),
        .init("archlinux", "Arch Linux", .linux, mem: 2048, cpus: 2, disk: 20),
        .init("alpine", "Alpine Linux", .linux, mem: 512, cpus: 1, disk: 8),

        // Windows
        .init("win11", "Windows 11", .windows, mem: 8192, cpus: 4, disk: 64,
              hyperv: true, tpm: true, uefi: true),
        .init("win10", "Windows 10", .windows, mem: 4096, cpus: 2, disk: 64,
              hyperv: true),
        .init("win2k25", "Windows Server 2025", .windows, mem: 4096, cpus: 4, disk: 64,
              hyperv: true, uefi: true),
        .init("win2k22", "Windows Server 2022", .windows, mem: 4096, cpus: 4, disk: 64,
              hyperv: true),

        // BSD
        .init("freebsd14", "FreeBSD 14", .bsd, mem: 1024, cpus: 1, disk: 16),
        .init("openbsd7", "OpenBSD 7", .bsd, mem: 1024, cpus: 1, disk: 16),

        // Generic fallback
        .init("generic", "Unknown / Other OS", .generic, mem: 2048, cpus: 2, disk: 20),
    ]

    public static func all(in family: Family) -> [GuestOS] {
        catalog.filter { $0.family == family }
    }

    public static func defaultOS(in family: Family) -> GuestOS {
        all(in: family).first ?? catalog[0]
    }

    /// One-line summary of the tuning this profile applies (shown in the wizard).
    public var tuningSummary: String {
        var parts = ["\(diskBus) disk", "\(nicModel) NIC", "\(clockOffset) clock"]
        if hyperv { parts.append("Hyper-V enlightenments") }
        if requiresTPM { parts.append("TPM 2.0") }
        if requiresUEFI { parts.append("UEFI required") }
        return parts.joined(separator: " · ")
    }
}
