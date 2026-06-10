import SwiftUI
import LibvirtKit

enum Format {
    /// Formats a KiB value as a human-readable memory size.
    static func memory(kiB: UInt64) -> String {
        let bytes = Double(kiB) * 1024
        let units = ["KiB", "MiB", "GiB", "TiB"]
        var value = Double(kiB)
        var unit = 0
        while value >= 1024 && unit < units.count - 1 {
            value /= 1024; unit += 1
        }
        _ = bytes
        return String(format: value < 10 ? "%.1f %@" : "%.0f %@", value, units[unit])
    }
}

extension DomainState {
    /// Color used for the status dot in the sidebar.
    var color: Color {
        switch self {
        case .running:                       return .green
        case .paused, .pmSuspended:          return .orange
        case .shuttingDown:                  return .yellow
        case .crashed:                       return .red
        case .shutoff, .noState, .blocked:   return .secondary
        }
    }

    var symbol: String {
        switch self {
        case .running:               return "play.circle.fill"
        case .paused, .pmSuspended:  return "pause.circle.fill"
        case .shuttingDown:          return "arrow.down.circle.fill"
        case .crashed:               return "exclamationmark.triangle.fill"
        default:                     return "stop.circle"
        }
    }
}
