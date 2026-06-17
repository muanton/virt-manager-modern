import SwiftUI

@main
struct VirtManagerModernApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var preferences = AppPreferences.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(preferences)
                .frame(minWidth: 920, minHeight: 580)
                .task { await appState.connectAutostart() }
        }
        .windowToolbarStyle(.unified)

        Settings {
            PreferencesView(prefs: preferences)
        }
    }
}
