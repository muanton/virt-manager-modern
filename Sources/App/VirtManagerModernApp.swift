import SwiftUI

@main
struct VirtManagerModernApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 920, minHeight: 580)
                .task { await appState.connectAutostart() }
        }
        .windowToolbarStyle(.unified)
    }
}
