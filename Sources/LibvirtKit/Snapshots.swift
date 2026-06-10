import CLibvirt
import Foundation

/// One domain snapshot (internal qcow2 snapshot incl. memory when taken live).
public struct Snapshot: Sendable, Identifiable {
    public let name: String
    public let description: String?
    public let created: Date?
    public let state: String        // "running", "shutoff", …
    public let parent: String?      // parent snapshot name (tree)
    public let isCurrent: Bool
    public var id: String { name }
}

extension LibvirtConnection {
    public func listSnapshots(uuid: String) async throws -> [Snapshot] {
        try await run { conn in
            try Self.withDomain(conn, uuid: uuid) { dom in
                var snaps: UnsafeMutablePointer<virDomainSnapshotPtr?>?
                let n = virDomainListAllSnapshots(dom, &snaps, 0)
                guard n >= 0, let snaps else {
                    throw LibvirtError.lastError(fallback: "Failed to list snapshots")
                }
                defer {
                    for i in 0..<Int(n) { virDomainSnapshotFree(snaps[i]) }
                    free(snaps)
                }
                var out: [Snapshot] = []
                for i in 0..<Int(n) {
                    guard let snap = snaps[i],
                          let xmlC = virDomainSnapshotGetXMLDesc(snap, 0) else { continue }
                    defer { free(xmlC) }
                    let isCurrent = virDomainSnapshotIsCurrent(snap, 0) == 1
                    if let s = Self.parseSnapshot(xml: String(cString: xmlC), isCurrent: isCurrent) {
                        out.append(s)
                    }
                }
                return out.sorted { ($0.created ?? .distantPast) < ($1.created ?? .distantPast) }
            }
        }
    }

    /// Creates a snapshot. For a running VM with qcow2 disks this is a full
    /// system snapshot (disks + memory); libvirt reports a clear error otherwise.
    public func createSnapshot(uuid: String, name: String, description: String) async throws {
        let xml = """
        <domainsnapshot>
          <name>\(Self.xmlEscape(name))</name>
          \(description.isEmpty ? "" : "<description>\(Self.xmlEscape(description))</description>")
        </domainsnapshot>
        """
        try await run { conn in
            try Self.withDomain(conn, uuid: uuid) { dom in
                guard let snap = virDomainSnapshotCreateXML(dom, xml, 0) else {
                    throw LibvirtError.lastError(fallback: "Failed to create snapshot")
                }
                virDomainSnapshotFree(snap)
            }
        }
    }

    public func revertToSnapshot(uuid: String, name: String) async throws {
        try await run { conn in
            try Self.withDomain(conn, uuid: uuid) { dom in
                guard let snap = virDomainSnapshotLookupByName(dom, name, 0) else {
                    throw LibvirtError.lastError(fallback: "Snapshot \(name) not found")
                }
                defer { virDomainSnapshotFree(snap) }
                guard virDomainRevertToSnapshot(snap, 0) == 0 else {
                    throw LibvirtError.lastError(fallback: "Failed to revert to \(name)")
                }
            }
        }
    }

    public func deleteSnapshot(uuid: String, name: String) async throws {
        try await run { conn in
            try Self.withDomain(conn, uuid: uuid) { dom in
                guard let snap = virDomainSnapshotLookupByName(dom, name, 0) else {
                    throw LibvirtError.lastError(fallback: "Snapshot \(name) not found")
                }
                defer { virDomainSnapshotFree(snap) }
                guard virDomainSnapshotDelete(snap, 0) == 0 else {
                    throw LibvirtError.lastError(fallback: "Failed to delete \(name)")
                }
            }
        }
    }

    // MARK: - Parsing

    static func parseSnapshot(xml: String, isCurrent: Bool) -> Snapshot? {
        guard let doc = try? XMLDocument(xmlString: xml), let root = doc.rootElement() else {
            return nil
        }
        func text(_ name: String) -> String? {
            root.elements(forName: name).first?.stringValue
        }
        guard let name = text("name") else { return nil }
        let created = text("creationTime").flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0) }
        let parent = root.elements(forName: "parent").first?
            .elements(forName: "name").first?.stringValue
        return Snapshot(name: name,
                        description: text("description"),
                        created: created,
                        state: text("state") ?? "unknown",
                        parent: parent,
                        isCurrent: isCurrent)
    }

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
