import Foundation
import Combine

/// Identifies a selected domain within a session (sidebar selection value).
struct DomainSelection: Hashable {
    let sessionID: UUID
    let uuid: String
}

/// Top-level app model: owns the saved connection configs and their live
/// sessions, and persists configs to Application Support.
@MainActor
final class AppState: ObservableObject {
    @Published private(set) var sessions: [ConnectionSession] = []

    /// Which detail tab each VM was last on ("sessionID/uuid" → tab index).
    /// Runtime-only by design — not persisted, and deliberately not @Published
    /// (it's read back on view appearance, never drives updates).
    var detailTabs: [String: Int] = [:]

    private let storeURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VirtManagerModern", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        storeURL = support.appendingPathComponent("connections.json")

        var configs = Self.load(from: storeURL) ?? []
        // The test:///default connection is a development aid: present only
        // when VMM_TEST_DRIVER=1 (e.g. `make run-dev`), never persisted.
        configs.removeAll { $0.isBuiltIn }
        if Self.testDriverEnabled { configs.insert(.testDriver, at: 0) }
        sessions = configs.map { ConnectionSession(config: $0) }
    }

    private static var testDriverEnabled: Bool {
        ProcessInfo.processInfo.environment["VMM_TEST_DRIVER"] == "1"
    }

    func session(id: UUID) -> ConnectionSession? {
        sessions.first { $0.id == id }
    }

    /// On launch, connect only the sessions marked autoconnect.
    func connectAutostart() async {
        await withTaskGroup(of: Void.self) { group in
            for s in sessions where s.config.autoconnect {
                group.addTask { await s.connect() }
            }
        }
    }

    /// Adds a new connection and connects it immediately.
    func addConnection(_ config: ConnectionConfig) {
        let session = ConnectionSession(config: config)
        sessions.append(session)
        persist()
        Task { await session.connect() }
    }

    /// Replaces an existing connection's config (reconnecting it).
    func updateConnection(_ config: ConnectionConfig) {
        guard let idx = sessions.firstIndex(where: { $0.id == config.id }) else {
            addConnection(config); return
        }
        sessions[idx].disconnect()
        let session = ConnectionSession(config: config)
        sessions[idx] = session
        persist()
        Task { await session.connect() }
    }

    func removeConnection(id: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].disconnect()
        sessions.remove(at: idx)
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        // The dev-only test driver never lands in the store.
        let configs = sessions.map(\.config).filter { !$0.isBuiltIn }
        if let data = try? JSONEncoder().encode(configs) {
            try? data.write(to: storeURL, options: .atomic)
        }
    }

    private static func load(from url: URL) -> [ConnectionConfig]? {
        guard let data = try? Data(contentsOf: url),
              let configs = try? JSONDecoder().decode([ConnectionConfig].self, from: data)
        else { return nil }
        return configs
    }
}
