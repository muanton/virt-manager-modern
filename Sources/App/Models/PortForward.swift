import Foundation
import ConsoleKit

/// One guest port forward: an `ssh -L` tunnel from `localhost:localPort` to
/// `guestIP:guestPort`, routed through the libvirt host. Owned by
/// `ConnectionSession` so it survives VM selection / tab changes.
struct PortForward: Identifiable {
    enum Status: Equatable {
        case starting
        case active
        case failed(String)
    }

    let id = UUID()
    let vmUUID: String
    let guestIP: String
    let guestPort: Int
    var localPort: Int
    var label: String
    var status: Status
    /// nil only when the tunnel could not be created (e.g. no free local port).
    let tunnel: SSHTunnel?

    /// True while the forward has (or is establishing) a usable local endpoint.
    var isLive: Bool { status == .starting || status == .active }
}
