import CLibvirt
import Foundation

/// An error surfaced from the libvirt C API.
/// Conforms to `LocalizedError` — a plain `localizedDescription` property is
/// ignored by Foundation's Error bridging, which yields the useless
/// "(LibvirtKit.LibvirtError error 1.)" instead of libvirt's message.
public struct LibvirtError: LocalizedError, CustomStringConvertible, Sendable {
    public let message: String
    public let code: Int32

    public init(message: String, code: Int32 = -1) {
        self.message = message
        self.code = code
    }

    public var description: String { message }
    public var errorDescription: String? { message }

    /// Builds an error from libvirt's thread-local last-error slot, falling back
    /// to `fallback` when libvirt has no error recorded.
    static func lastError(fallback: String) -> LibvirtError {
        if let err = virGetLastError() {
            let msg = err.pointee.message.map { String(cString: $0) } ?? fallback
            return LibvirtError(message: msg, code: err.pointee.code)
        }
        return LibvirtError(message: fallback)
    }
}
