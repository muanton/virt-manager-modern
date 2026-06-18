import Foundation
import Combine

/// User defaults surfaced to SwiftUI (Settings window + console behaviour).
@MainActor
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()

    @Published var spiceClipboardEnabled: Bool {
        didSet { Self.set(spiceClipboardEnabled, forKey: Keys.spiceClipboard) }
    }
    @Published var vncClipboardEnabled: Bool {
        didSet { Self.set(vncClipboardEnabled, forKey: Keys.vncClipboard) }
    }
    @Published var spiceAudioEnabled: Bool {
        didSet { Self.set(spiceAudioEnabled, forKey: Keys.spiceAudio) }
    }
    @Published var spiceUsbEnabled: Bool {
        didSet { Self.set(spiceUsbEnabled, forKey: Keys.spiceUsb) }
    }
    /// Detail tab index when opening a VM: 0 Overview, 1 Console, 2 Hardware, 3 Snapshots.
    @Published var defaultDetailTab: Int {
        didSet { Self.set(defaultDetailTab, forKey: Keys.defaultDetailTab) }
    }

    private enum Keys {
        static let spiceClipboard = "prefs.spiceClipboard"
        static let spiceAudio = "prefs.spiceAudio"
        static let spiceUsb = "prefs.spiceUsb"
        static let vncClipboard = "prefs.vncClipboard"
        static let defaultDetailTab = "prefs.defaultDetailTab"
    }

    private init() {
        let d = UserDefaults.standard
        spiceClipboardEnabled = d.object(forKey: Keys.spiceClipboard) as? Bool ?? true
        spiceAudioEnabled = d.object(forKey: Keys.spiceAudio) as? Bool ?? true
        spiceUsbEnabled = d.object(forKey: Keys.spiceUsb) as? Bool ?? true
        vncClipboardEnabled = d.object(forKey: Keys.vncClipboard) as? Bool ?? true
        defaultDetailTab = min(3, max(0, d.integer(forKey: Keys.defaultDetailTab)))
    }

    private static func set(_ value: Bool, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    private static func set(_ value: Int, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}