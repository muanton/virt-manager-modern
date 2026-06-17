import CLibvirt
import Foundation

/// Runtime state of a domain (mirrors libvirt's `virDomainState`).
public enum DomainState: Int32, Sendable, CaseIterable {
    case noState = 0
    case running = 1
    case blocked = 2
    case paused = 3
    case shuttingDown = 4
    case shutoff = 5
    case crashed = 6
    case pmSuspended = 7

    init(raw: Int32) {
        self = DomainState(rawValue: raw) ?? .noState
    }

    public var label: String {
        switch self {
        case .noState: return "Unknown"
        case .running: return "Running"
        case .blocked: return "Blocked"
        case .paused: return "Paused"
        case .shuttingDown: return "Shutting Down"
        case .shutoff: return "Shut Off"
        case .crashed: return "Crashed"
        case .pmSuspended: return "Suspended"
        }
    }

    public var isActive: Bool {
        switch self {
        case .running, .blocked, .paused, .shuttingDown, .pmSuspended:
            return true
        case .noState, .shutoff, .crashed:
            return false
        }
    }

    public var isPaused: Bool { self == .paused || self == .pmSuspended }
}

/// An immutable, `Sendable` snapshot of a domain's identity and runtime info.
/// We extract this on the libvirt queue so UI code never touches `virDomainPtr`.
public struct DomainSummary: Identifiable, Sendable, Hashable {
    public let uuid: String
    public let name: String
    public let domainID: Int32    // libvirt runtime domain id, -1 when inactive
    public let state: DomainState
    public let vcpus: Int
    public let memoryKiB: UInt64      // current allocation
    public let maxMemoryKiB: UInt64

    /// SwiftUI identity. Must be the UUID: libvirt's numeric domain id is -1
    /// for every inactive domain, so it collides as soon as two VMs are off.
    public var id: String { uuid }

    public var isActive: Bool { state.isActive }
}

/// Lifecycle actions that can be performed on a domain.
public enum DomainAction: Sendable {
    case start
    case shutdown        // graceful ACPI
    case reboot
    case forceOff        // destroy
    case pause           // suspend
    case resume
    case save            // managedSave
    case undefine        // delete definition (keeps disks)
}
